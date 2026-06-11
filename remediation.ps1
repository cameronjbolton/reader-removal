<#
.SYNOPSIS
    Remediation script: removes EVERY 32-bit Adobe Acrobat / Acrobat Reader
    install (any version), then installs the unified 64-bit Acrobat if no
    64-bit Acrobat is already present. Sets FeatureLockDown keys so the
    unified app runs in Reader mode without forced sign-in (licensed users
    can still sign in to unlock Standard/Pro).

.NOTES
    - Runs as SYSTEM via Intune Proactive Remediations.
    - Logs to C:\ProgramData\AcrobatRemediation\.
    - 32-bit installs are identified by their registration under WOW6432Node.
    - The unified installer URL is version-independent (always latest), so no
      monthly maintenance is required in this script.
#>

# ============================================================
# CONFIG
# ============================================================
$InstallerUrl  = "https://trials.adobe.com/AdobeProducts/APRO/Acrobat_HelpX/win32/Acrobat_DC_Web_x64_WWMUI.zip"
$LogDir        = "C:\ProgramData\AcrobatRemediation"
$KillProcesses = $true
# ============================================================

New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
$LogFile = Join-Path $LogDir ("Remediate32-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
function Write-Log ($msg) {
    Add-Content -Path $LogFile -Value ("{0:u}  {1}" -f (Get-Date), $msg)
    Write-Output $msg
}

$Wow64Root  = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
$NativeRoot = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"

function Get-AcrobatInstalls ($root, $arch) {
    if (-not (Test-Path $root)) { return }
    Get-ChildItem $root | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if (-not $p.DisplayName) { return }
        if ($p.DisplayName -match '^Adobe (Acrobat|Reader)' -and
            $p.DisplayName -notmatch 'Refresh Manager|Genuine|Creative Cloud') {
            [pscustomobject]@{
                DisplayName     = $p.DisplayName
                DisplayVersion  = $p.DisplayVersion
                ProductCode     = $_.PSChildName
                Architecture    = $arch
                UninstallString = $p.UninstallString
            }
        }
    }
}

function Set-AcrobatPolicyKeys {
    $fld = "HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown"
    $ipm = Join-Path $fld "cIPM"
    foreach ($k in $fld, $ipm) {
        if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
    }
    New-ItemProperty -Path $fld -Name 'bIsSCReducedModeEnforcedEx' -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $ipm -Name 'bDontShowMsgWhenViewingDoc' -Value 0 -PropertyType DWord -Force | Out-Null
    Write-Log "Set FeatureLockDown keys: bIsSCReducedModeEnforcedEx=1, cIPM\bDontShowMsgWhenViewingDoc=0"
}

# ------------------------------------------------------------
# 1. Enumerate
# ------------------------------------------------------------
$x86Installs = @(Get-AcrobatInstalls $Wow64Root  'x86')
$x64Installs = @(Get-AcrobatInstalls $NativeRoot 'x64')

Write-Log "32-bit Acrobat installs: $($x86Installs.Count)"
$x86Installs | ForEach-Object { Write-Log "  [x86] $($_.DisplayName) $($_.DisplayVersion) $($_.ProductCode)" }
Write-Log "64-bit Acrobat installs: $($x64Installs.Count)"
$x64Installs | ForEach-Object { Write-Log "  [x64] $($_.DisplayName) $($_.DisplayVersion) $($_.ProductCode)" }

if ($x86Installs.Count -eq 0) {
    Set-AcrobatPolicyKeys   # detection may have fired on the missing policy key
    Write-Log "No 32-bit Acrobat present. Policy keys enforced. Done."
    exit 0
}

# ------------------------------------------------------------
# 2. Stop running Acrobat processes/services
# ------------------------------------------------------------
if ($KillProcesses) {
    foreach ($proc in 'Acrobat','AcroRd32','AcroCEF','AdobeCollabSync','acrobat_sl','AdobeARM') {
        Get-Process -Name $proc -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Log "Stopping process: $($_.Name) (PID $($_.Id))"
            $_ | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }
    Get-Service -Name 'AdobeARMservice' -ErrorAction SilentlyContinue |
        Where-Object Status -eq 'Running' | Stop-Service -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------
# 3. Uninstall every 32-bit install
# ------------------------------------------------------------
$removedAny = $false
foreach ($app in $x86Installs) {
    Write-Log "Uninstalling: $($app.DisplayName) $($app.DisplayVersion) [x86]"

    if ($app.ProductCode -match '^\{[0-9A-Fa-f\-]{36}\}$') {
        $proc = Start-Process msiexec.exe `
            -ArgumentList "/x $($app.ProductCode) /qn /norestart REBOOT=ReallySuppress" `
            -Wait -PassThru
        $code = $proc.ExitCode
    }
    elseif ($app.UninstallString) {
        Write-Log "  Non-MSI entry, using UninstallString: $($app.UninstallString)"
        $proc = Start-Process cmd.exe -ArgumentList "/c `"$($app.UninstallString) /qn /norestart`"" -Wait -PassThru
        $code = $proc.ExitCode
    }
    else {
        Write-Log "  ERROR: no product code or uninstall string; skipping."
        continue
    }

    switch ($code) {
        0       { Write-Log "  Uninstalled OK.";                        $removedAny = $true }
        3010    { Write-Log "  Uninstalled OK (3010: reboot pending)."; $removedAny = $true }
        1605    { Write-Log "  Already gone (1605).";                   $removedAny = $true }
        default { Write-Log "  WARNING: msiexec exit code $code." }
    }
}

# ------------------------------------------------------------
# 4. Install unified 64-bit Acrobat if a 32-bit version was removed
#    and no 64-bit Acrobat already exists
# ------------------------------------------------------------
if ($removedAny -and $x64Installs.Count -eq 0) {
    $work = Join-Path $env:TEMP "AcrobatUnified"
    $zip  = Join-Path $work "AcrobatUnified.zip"
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path $work -ItemType Directory -Force | Out-Null

    try {
        Write-Log "Downloading unified installer: $InstallerUrl"
        try {
            Start-BitsTransfer -Source $InstallerUrl -Destination $zip -ErrorAction Stop
        } catch {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $InstallerUrl -OutFile $zip -UseBasicParsing
        }
        if (-not (Test-Path $zip)) { throw "Download failed." }

        Write-Log "Extracting installer package..."
        Expand-Archive -Path $zip -DestinationPath $work -Force

        $setup = Get-ChildItem -Path $work -Filter "setup.exe" -Recurse | Select-Object -First 1
        if (-not $setup) { throw "setup.exe not found in extracted package." }

        $sig = Get-AuthenticodeSignature $setup.FullName
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Adobe') {
            throw "Installer signature invalid or not Adobe-signed: $($sig.Status)"
        }

        # Policy keys BEFORE install so no user ever hits a sign-in wall
        Set-AcrobatPolicyKeys

        Write-Log "Installing unified Acrobat 64-bit (silent)..."
        $proc = Start-Process $setup.FullName `
            -ArgumentList "/sAll /rs /msi EULA_ACCEPT=YES DISABLEDESKTOPSHORTCUT=1" `
            -Wait -PassThru
        Write-Log "Installer exit code: $($proc.ExitCode)"
        if ($proc.ExitCode -notin 0,3010) { throw "Install failed with exit code $($proc.ExitCode)." }
    }
    catch {
        Write-Log "ERROR during install: $($_.Exception.Message)"
        exit 1
    }
    finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
else {
    if ($removedAny) { Write-Log "Skipping install: 64-bit Acrobat already present." }
    Set-AcrobatPolicyKeys
}

# ------------------------------------------------------------
# 5. Verify final state: no 32-bit installs may remain
# ------------------------------------------------------------
$x86Remaining = @(Get-AcrobatInstalls $Wow64Root 'x86')
if ($x86Remaining.Count -gt 0) {
    $x86Remaining | ForEach-Object { Write-Log "STILL PRESENT: [x86] $($_.DisplayName) $($_.DisplayVersion)" }
    exit 1
}

$x64Final = @(Get-AcrobatInstalls $NativeRoot 'x64')
Write-Log "Remediation complete. 64-bit installs: $(($x64Final | ForEach-Object { "$($_.DisplayName) $($_.DisplayVersion)" }) -join '; ')"
exit 0
