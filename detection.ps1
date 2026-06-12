try {
    # On x64 Windows, 32-bit applications register under WOW6432Node.
    $Wow64Root   = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    $NativeRoot  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"


    # --- 32-bit Acrobat/Reader detection (any version) ---
    $x86Installs = @()
    if (Test-Path $Wow64Root) {
        $x86Installs = @(Get-ChildItem $Wow64Root | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName -match '^Adobe (Acrobat|Reader)' -and
                $p.DisplayName -notmatch 'Refresh Manager|Genuine|Creative Cloud') {
                "$($p.DisplayName) $($p.DisplayVersion)"
            }
        })
    }

    if ($x86Installs.Count -gt 0) {
        Write-Output "Non-compliant: 32-bit Acrobat present: $($x86Installs -join '; ')"
        exit 1
    }

    # --- No 32-bit installs. If 64-bit Acrobat exists, verify policy key. ---
    $x64Present = @(Get-ChildItem $NativeRoot -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($p.DisplayName -match '^Adobe (Acrobat|Reader)' -and
            $p.DisplayName -notmatch 'Refresh Manager|Genuine|Creative Cloud') { $p.DisplayName }
    })

    if ($x64Present.Count -gt 0) {
        $fld = "HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown"
        $val = (Get-ItemProperty -Path $fld -Name 'bIsSCReducedModeEnforcedEx' -ErrorAction SilentlyContinue).bIsSCReducedModeEnforcedEx
        if ($val -ne 1) {
            Write-Output "Non-compliant: 64-bit Acrobat present but bIsSCReducedModeEnforcedEx not set."
            exit 1
        }
    }

    Write-Output "Compliant: no 32-bit Acrobat installed."
    exit 0
}
catch {
    Write-Output "Detection error: $($_.Exception.Message)"
    exit 1
}
