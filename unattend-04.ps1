#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    Skrypt wdrożeniowy – konfiguracja systemu, instalacja oprogramowania,
    dołączenie do domeny, włączenie RDP i szyfrowanie BitLocker.
.NOTES
    Wersja  : 2.3
    Autor   : Michał Sawczuk
    Wymaga  : uprawnień administratora, dostępu do \\172.20.0.71
#>

# ── Transkrypt ─────────────────────────────────────────────────────────────────
$LogPath = "C:\Windows\Temp\unattend_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $LogPath -Append -ErrorAction SilentlyContinue

# ── Logowanie do konsoli ───────────────────────────────────────────────────────
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','OK','WARN','ERROR')]
        [string]$Level = 'INFO'
    )
    $palette = @{ INFO = 'Cyan'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red' }
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host "[$ts][$Level] $Message" -ForegroundColor $palette[$Level]
}

# ══════════════════════════════════════════════════════════════════════════════
# 0. OCZEKIWANIE NA POŁĄCZENIE Z INTERNETEM
# ══════════════════════════════════════════════════════════════════════════════
Write-Log 'Sprawdzanie połączenia z Internetem...'
$internetOk = $false
while (-not $internetOk) {
    try {
        # Test połączenia – ping do 8.8.8.8 z timeoutem 3 s
        $ping = [System.Net.NetworkInformation.Ping]::new()
        $reply = $ping.Send('8.8.8.8', 3000)
        if ($reply.Status -eq 'Success') {
            $internetOk = $true
            Write-Log 'Połączenie z Internetem: OK. Rozpoczynam skrypt.' OK
        }
        else {
            Write-Log 'Brak połączenia z Internetem. Kolejna próba za 5 sekund...' WARN
            Start-Sleep -Seconds 5
        }
    }
    catch {
        Write-Log "Błąd testu sieci: $_. Kolejna próba za 5 sekund..." WARN
        Start-Sleep -Seconds 5
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# 0b. OCZEKIWANIE NA UDZIAŁ SIECIOWY
# ══════════════════════════════════════════════════════════════════════════════
$ShareRoot  = '\\172.20.0.71\Public\Deploy'
$maxRetries = 12   # maks. 60 s oczekiwania (12 × 5 s)
$retries    = 0
Write-Log "Sprawdzanie dostępności udziału: $ShareRoot"
while (-not (Test-Path -LiteralPath $ShareRoot -ErrorAction SilentlyContinue)) {
    $retries++
    if ($retries -ge $maxRetries) {
        Write-Log "Udział $ShareRoot niedostępny po $($maxRetries * 5) s. Instalacje lokalne zostaną pominięte." WARN
        break
    }
    Write-Log "Udział niedostępny. Kolejna próba za 5 sekund... ($retries/$maxRetries)" WARN
    Start-Sleep -Seconds 5
}
if (Test-Path -LiteralPath $ShareRoot -ErrorAction SilentlyContinue) {
    Write-Log "Udział sieciowy dostępny: $ShareRoot" OK
}

# ══════════════════════════════════════════════════════════════════════════════
# 1. KONTA LOKALNE – hasła nigdy nie wygasają
# ══════════════════════════════════════════════════════════════════════════════
foreach ($u in 'IT','help') {
    try {
        Set-LocalUser -Name $u -PasswordNeverExpires $true -ErrorAction Stop
        Write-Log "Konto $u – PasswordNeverExpires ustawione." OK
    }
    catch {
        Write-Log "Błąd ustawiania PasswordNeverExpires dla $u`: $_" WARN
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# 2. ZASILANIE I HIBERNACJA
# ══════════════════════════════════════════════════════════════════════════════
Write-Log 'Konfiguracja zarządzania energią...'
powercfg.exe /hibernate off
powercfg.exe /change monitor-timeout-ac 0
powercfg.exe /change monitor-timeout-dc 0
powercfg.exe /change standby-timeout-ac 0
powercfg.exe /change standby-timeout-dc 0
Write-Log 'Hibernacja wyłączona, monitor i uśpienie → NIGDY.' OK

# ══════════════════════════════════════════════════════════════════════════════
# 3. .NET FRAMEWORK 3.5
# ══════════════════════════════════════════════════════════════════════════════
Write-Log 'Instalowanie .NET Framework 3.5...'
try {
    Enable-WindowsOptionalFeature -Online -FeatureName 'NetFx3' -All -NoRestart | Out-Null
    Write-Log '.NET Framework 3.5 zainstalowany.' OK
}
catch {
    Write-Log ".NET Framework 3.5 – błąd: $_" WARN
}

# ══════════════════════════════════════════════════════════════════════════════
# 4. APLIKACJE WINGET
# ══════════════════════════════════════════════════════════════════════════════
$wingetApps = @(
    'Microsoft.DotNet.DesktopRuntime.8'
    'Adobe.Acrobat.Reader.64-bit'
    '7zip.7zip'
    'Microsoft.Teams'
    'Microsoft.Office'
)

[double]$complete  = 0
[double]$increment = 100.0 / $wingetApps.Count
$spinner      = @('|','/','-','\')
$spinnerIndex = 0
$wingetFailed = [System.Collections.Generic.List[string]]::new()

foreach ($app in $wingetApps) {
    Write-Progress -Id 0 `
        -Activity    'Instalacja oprogramowania (Winget) – nie zamykaj okna.' `
        -Status      "Aktualnie: $app" `
        -PercentComplete ([Math]::Min([int]$complete, 100))

    $appLabel = $app.Trim()
    if ($appLabel.Length -gt 99) { $appLabel = $appLabel.Substring(0,99) + '…' }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = 'winget.exe'
    $psi.Arguments              = "install --id `"$app`" --exact --silent --accept-package-agreements --accept-source-agreements --scope machine"
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    $action = { }
    Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -Action $action | Out-Null
    Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived  -Action $action | Out-Null

    $null = $process.Start()
    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()

    while (-not $process.HasExited) {
        $char = $spinner[$spinnerIndex]
        $spinnerIndex = ($spinnerIndex + 1) % $spinner.Count
        Write-Host -NoNewline "    [$char] [Winget] Instalowanie: $appLabel...`r"
        Start-Sleep -Milliseconds 250
    }
    Write-Host -NoNewline (" " * 110 + "`r")

    switch ($process.ExitCode) {
        0       { Write-Log "Zainstalowano: $app" OK }
        default {
            Write-Log "Niezerowy kod wyjścia [$($process.ExitCode)] dla: $app" WARN
            $wingetFailed.Add("$app  (exit: $($process.ExitCode))")
        }
    }
    $complete += $increment
}

Write-Progress -Id 0 -Activity 'Instalacja oprogramowania (Winget)' -Completed
if ($wingetFailed.Count -gt 0) {
    Write-Log 'Aplikacje z błędem winget:' WARN
    $wingetFailed | ForEach-Object { Write-Log "  - $_" WARN }
}

# ══════════════════════════════════════════════════════════════════════════════
# 5a. NAV 2015
# ══════════════════════════════════════════════════════════════════════════════
$navScriptPath = '\\172.20.0.71\Public\Deploy\Apps\NAV\nav2015.bat'
$navConfigSrc  = '\\172.20.0.71\Public\Deploy\Apps\NAV\ClientUserSettings.config'
$navConfigDst  = 'C:\ProgramData\Microsoft\Microsoft Dynamics NAV\80\ClientUserSettings.config'

Write-Log 'Instalacja NAV 2015...'
if (Test-Path -LiteralPath $navScriptPath) {
    try {
        $nav = Start-Process -FilePath 'cmd.exe' `
            -ArgumentList "/c `"$navScriptPath`"" `
            -NoNewWindow -Wait -PassThru -ErrorAction Stop
        if ($nav.ExitCode -eq 0) {
            Write-Log 'NAV 2015 zainstalowany pomyślnie.' OK
            # Katalog docelowy może nie istnieć przed instalacją – tworzymy go
            $navConfigDir = Split-Path $navConfigDst
            if (-not (Test-Path $navConfigDir)) {
                New-Item -ItemType Directory -Path $navConfigDir -Force | Out-Null
            }
            Copy-Item -LiteralPath $navConfigSrc -Destination $navConfigDst -Force
            Write-Log 'Konfiguracja NAV skopiowana.' OK
        }
        else {
            Write-Log "NAV 2015 zakończył z kodem: $($nav.ExitCode)" WARN
        }
    }
    catch {
        Write-Log "Wyjątek podczas instalacji NAV 2015: $_" ERROR
    }
}
else {
    Write-Log "Nie znaleziono: $navScriptPath – instalacja NAV pominięta." ERROR
}

# ══════════════════════════════════════════════════════════════════════════════
# 5b. ANYDESK
# ══════════════════════════════════════════════════════════════════════════════
$anydeskPath = '\\172.20.0.71\Public\Deploy\Apps\Anydesk\AnyDeskClientTelemond.msi'

Write-Log 'Instalacja AnyDesk...'
if (Test-Path -LiteralPath $anydeskPath) {
    try {
        $anydesk = Start-Process -FilePath 'msiexec.exe' `
            -ArgumentList "/i `"$anydeskPath`" /qn /norestart" `
            -NoNewWindow -Wait -PassThru -ErrorAction Stop
        if ($anydesk.ExitCode -eq 0) {
            Write-Log 'AnyDesk zainstalowany pomyślnie.' OK
        }
        else {
            Write-Log "AnyDesk zakończył z kodem: $($anydesk.ExitCode)" WARN
        }
    }
    catch {
        Write-Log "Wyjątek podczas instalacji AnyDesk: $_" ERROR
    }
}
else {
    Write-Log "Nie znaleziono: $anydeskPath – instalacja AnyDesk pominięta." ERROR
}

# ══════════════════════════════════════════════════════════════════════════════
# 5c. TIGHTVNC
# ══════════════════════════════════════════════════════════════════════════════
$tightvncPath = '\\172.20.0.71\Public\Deploy\Apps\Tight\tightvnc.msi'

Write-Log 'Instalacja TightVNC...'
if (Test-Path -LiteralPath $tightvncPath) {
    try {
        $tightvnc = Start-Process -FilePath 'msiexec.exe' `
            -ArgumentList "/i `"$tightvncPath`" /qn /norestart" `
            -NoNewWindow -Wait -PassThru -ErrorAction Stop
        if ($tightvnc.ExitCode -eq 0) {
            Write-Log 'TightVNC zainstalowany pomyślnie.' OK
        }
        else {
            Write-Log "TightVNC zakończył z kodem: $($tightvnc.ExitCode)" WARN
        }
    }
    catch {
        Write-Log "Wyjątek podczas instalacji TightVNC: $_" ERROR
    }
}
else {
    Write-Log "Nie znaleziono: $tightvncPath – instalacja TightVNC pominięta." ERROR
}

# ══════════════════════════════════════════════════════════════════════════════
# 6. DOŁĄCZENIE DO DOMENY
# ══════════════════════════════════════════════════════════════════════════════
Write-Log 'Dołączanie do domeny telemond.holding...'
try {
    $domainCred = Get-Credential -Message 'Konto z prawem dołączenia do telemond.holding:'
    Add-Computer -DomainName 'telemond.holding' -Credential $domainCred -ErrorAction Stop
    Write-Log 'Komputer dołączył do domeny. Wymagany restart.' OK
}
catch {
    Write-Log "Błąd dołączania do domeny: $_" ERROR
}

# ══════════════════════════════════════════════════════════════════════════════
# 7. RDP
# ══════════════════════════════════════════════════════════════════════════════
Write-Log 'Włączanie RDP...'
Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
    -Name 'fDenyTSConnections' -Value 0
Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
    -Name 'UserAuthentication' -Value 1

# Włączamy każdą regułę RDP jawnie, żeby Enable-NetFirewallRule nie zwracał błędu
Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue |
    ForEach-Object { Enable-NetFirewallRule -Name $_.Name -ErrorAction SilentlyContinue }

Write-Log 'RDP włączone (rejestr + zapora).' OK

# Tłumaczymy SID S-1-5-32-555 na lokalną nazwę grupy Remote Desktop Users
$rdpSID       = [System.Security.Principal.SecurityIdentifier]'S-1-5-32-555'
$rdpGroupName = $rdpSID.Translate([System.Security.Principal.NTAccount]).Value.Split('\')[1]

foreach ($account in @('telemond.holding\Domain Admins','telemond.holding\Enterprise Admins')) {
    try {
        $members = Get-LocalGroupMember -Group $rdpGroupName -ErrorAction Stop |
            Select-Object -ExpandProperty Name
        if ($members -contains $account) {
            Write-Log "$account już w grupie $rdpGroupName." INFO
        }
        else {
            Add-LocalGroupMember -Group $rdpGroupName -Member $account -ErrorAction Stop
            Write-Log "Dodano $account do $rdpGroupName." OK
        }
    }
    catch {
        Write-Log "Nie dodano $account`: $_" ERROR
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# 8. BITLOCKER
# ══════════════════════════════════════════════════════════════════════════════
$DriveLetter  = 'C:'
$BLFolder     = '\\172.20.0.71\Public\Deploy\BL\'
$IpConfigPath = Join-Path $BLFolder "Siec_$env:COMPUTERNAME.txt"
$BackupPath   = Join-Path $BLFolder "KluczOdzyskiwania_$env:COMPUTERNAME.txt"

try {
    ipconfig /all | Out-File -FilePath $IpConfigPath -Encoding utf8 -Force
    Write-Log "Konfiguracja sieciowa zapisana: $IpConfigPath" OK
}
catch { Write-Log "Nie można zapisać ipconfig: $_" WARN }

Write-Log 'Sprawdzanie TPM i stanu BitLocker...'
try {
    $tpm = Get-Tpm -ErrorAction Stop
    Write-Log "TPM – Present:$($tpm.TpmPresent) Enabled:$($tpm.TpmEnabled) Activated:$($tpm.TpmActivated)" INFO
}
catch { Write-Log "Błąd pobierania TPM: $_" WARN }

try {
    $blStatus = Get-BitLockerVolume -MountPoint $DriveLetter -ErrorAction Stop
    Write-Log "Stan BitLocker: $($blStatus.VolumeStatus)" INFO

    if ($blStatus.VolumeStatus -in 'FullyEncrypted','EncryptionInProgress','EncryptionPaused','EncryptionSuspended') {
        Write-Log 'BitLocker aktywny – wyłączanie i czyszczenie przed ponowną konfiguracją...' INFO
        try {
            manage-bde -off $DriveLetter 2>&1 | Out-Null
            $timeout = 0; $maxWait = 240
            while ($timeout -lt $maxWait) {
                if ((manage-bde -status $DriveLetter 2>&1) -match 'Fully Decrypted') {
                    Write-Log 'Odszyfrowanie zakończone.' OK; break
                }
                Start-Sleep -Seconds 2; $timeout += 2
                if ($timeout % 10 -eq 0) { Write-Host -NoNewline '.' }
            }
            if ($timeout -ge $maxWait) { Write-Log 'Timeout odszyfrowania – kontynuuję.' WARN }
            manage-bde -protectors -delete $DriveLetter 2>&1 | Out-Null
            Write-Log 'Protektory usunięte.' OK
        }
        catch { Write-Log "Błąd czyszczenia BitLocker: $_" WARN }
    }

    Write-Log 'Włączanie BitLocker...'
    try {
        Enable-BitLocker -MountPoint $DriveLetter -RecoveryPasswordProtector -SkipHardwareTest -ErrorAction Stop | Out-Null
        Write-Log 'BitLocker włączony.' OK
        Resume-BitLocker -MountPoint $DriveLetter -ErrorAction SilentlyContinue | Out-Null
        Add-BitLockerKeyProtector -MountPoint $DriveLetter -TpmProtector -ErrorAction SilentlyContinue | Out-Null
    }
    catch [System.Management.Automation.ParameterBindingException] {
        Write-Log 'Próba bez -SkipHardwareTest...' INFO
        try {
            Enable-BitLocker -MountPoint $DriveLetter -RecoveryPasswordProtector -ErrorAction Stop | Out-Null
            Write-Log 'BitLocker włączony (bez SkipHardwareTest).' OK
            Resume-BitLocker -MountPoint $DriveLetter -ErrorAction SilentlyContinue | Out-Null
            Add-BitLockerKeyProtector -MountPoint $DriveLetter -TpmProtector -ErrorAction SilentlyContinue | Out-Null
        }
        catch {
            Write-Log "Fallback manage-bde..." INFO
            $r = & manage-bde -protectors -add $DriveLetter -rp 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Log 'BitLocker włączony (manage-bde).' OK
                Resume-BitLocker -MountPoint $DriveLetter -ErrorAction SilentlyContinue | Out-Null
                & manage-bde -protectors -add C: -tpm | Out-Null
            }
            else { Write-Log "manage-bde błąd $LASTEXITCODE`: $r" ERROR }
        }
    }
    catch { Write-Log "Błąd Enable-BitLocker: $_" ERROR }
}
catch { Write-Log "Nie można pobrać stanu BitLocker: $_" ERROR }

# ── Eksport klucza odzyskiwania ────────────────────────────────────────────────
try {
    $blFinal = Get-BitLockerVolume -MountPoint $DriveLetter -ErrorAction Stop
    $recoveryProtector = $blFinal.KeyProtector |
        Where-Object KeyProtectorType -eq 'RecoveryPassword' |
        Select-Object -First 1

    if ($recoveryProtector) {
        $keyContent = @"
==================================================
KOPIA ZAPASOWA KLUCZA ODZYSKIWANIA BITLOCKER
==================================================
Data               : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Komputer           : $env:COMPUTERNAME
Dysk               : $DriveLetter
ID protektora      : $($recoveryProtector.KeyProtectorId)
Klucz odzyskiwania : $($recoveryProtector.RecoveryPassword)
==================================================
"@
        $saved = $false
        if (Test-Path -LiteralPath $BLFolder -ErrorAction SilentlyContinue) {
            try {
                $keyContent | Out-File -FilePath $BackupPath -Encoding utf8 -Force
                Write-Log "Klucz odzyskiwania zapisany: $BackupPath" OK
                $saved = $true
            }
            catch { Write-Log "Zapis sieciowy nie powiódł się: $_" WARN }
        }
        if (-not $saved) {
            $localKey = "C:\Windows\Panther\RecoveryKey_$env:COMPUTERNAME.txt"
            New-Item -ItemType Directory -Path (Split-Path $localKey) -Force -ErrorAction SilentlyContinue | Out-Null
            $keyContent | Out-File -FilePath $localKey -Encoding utf8 -Force
            Write-Log "Klucz zapisany lokalnie: $localKey" WARN
        }
    }
    else { Write-Log 'Brak protektora RecoveryPassword.' WARN }
    Write-Log "Finalny stan BitLocker: $($blFinal.VolumeStatus) ($($blFinal.EncryptionPercentage)%)" INFO
}
catch { Write-Log "Błąd eksportu klucza: $_" ERROR }

# ══════════════════════════════════════════════════════════════════════════════
# 9. WERYFIKACJA POWDROŻENIOWA
# ══════════════════════════════════════════════════════════════════════════════
Write-Log '══════════════════ WERYFIKACJA ═════════════════' INFO
$testResults = [System.Collections.Generic.List[PSCustomObject]]::new()

function Test-Check {
    param([string]$Name, [scriptblock]$Test)
    try {
        $ok     = [bool](& $Test)
        $status = if ($ok) { 'PASS' } else { 'FAIL' }
        $info   = ''
    }
    catch {
        $status = 'FAIL'
        $info   = $_.ToString()
    }
    $script:testResults.Add([PSCustomObject]@{ Test = $Name; Status = $status; Info = $info })
    $lv = if ($status -eq 'PASS') { 'OK' } else { 'WARN' }
    Write-Log "  [$status]  $Name$(if ($info) { " – $info" })" $lv
}

# 9.1 Konta lokalne
# UWAGA: PasswordNeverExpires musi być sprawdzane przez Get-LocalUser, nie przez -PasswordNeverExpires
Test-Check 'Konto IT istnieje' {
    [bool](Get-LocalUser -Name 'IT' -ErrorAction SilentlyContinue)
}
Test-Check 'Konto help istnieje' {
    [bool](Get-LocalUser -Name 'help' -ErrorAction SilentlyContinue)
}
Test-Check 'Hasło konta IT nie wygasa' {
    # PasswordNeverExpires zwraca bool bezpośrednio – nie potrzeba konwersji
    (Get-LocalUser -Name 'IT' -ErrorAction SilentlyContinue).PasswordNeverExpires -eq $true
}
Test-Check 'Hasło konta help nie wygasa' {
    (Get-LocalUser -Name 'help' -ErrorAction SilentlyContinue).PasswordNeverExpires -eq $true
}

# 9.2 Zasilanie
Test-Check 'Hibernacja wyłączona' {
    # hiberfil.sys znika po wyłączeniu hibernacji
    -not (Test-Path 'C:\hiberfil.sys')
}
Test-Check 'Monitor timeout AC = 0' {
    $out = powercfg /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 2>&1 | Out-String
    $out -match 'Current AC Power Setting Index: 0x00000000'
}
Test-Check 'Standby timeout AC = 0' {
    $out = powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>&1 | Out-String
    $out -match 'Current AC Power Setting Index: 0x00000000'
}

# 9.3 .NET 3.5
Test-Check '.NET Framework 3.5 włączony' {
    (Get-WindowsOptionalFeature -Online -FeatureName 'NetFx3' -ErrorAction SilentlyContinue).State -eq 'Enabled'
}

# 9.4 Aplikacje (rejestr)
$uninstallPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
function Find-InstalledApp([string]$Pattern) {
    [bool](Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like $Pattern })
}

Test-Check 'Zainstalowano: AnyDesk'       { Find-InstalledApp '*AnyDesk*' }
Test-Check 'Zainstalowano: TightVNC'      { Find-InstalledApp '*TightVNC*' }
Test-Check 'Zainstalowano: Adobe Acrobat' { Find-InstalledApp '*Adobe Acrobat*' }
Test-Check 'Zainstalowano: MS Teams'      { Find-InstalledApp '*Teams*' }
Test-Check 'Zainstalowano: 7-Zip'         { Find-InstalledApp '*7-Zip*' }

# 9.5 NAV 2015 – plik konfiguracyjny
Test-Check 'NAV – ClientUserSettings.config istnieje' {
    Test-Path 'C:\ProgramData\Microsoft\Microsoft Dynamics NAV\80\ClientUserSettings.config'
}

# 9.6 RDP
Test-Check 'RDP włączone (rejestr)' {
    (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server').fDenyTSConnections -eq 0
}
Test-Check 'NLA włączone (rejestr)' {
    (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp').UserAuthentication -eq 1
}
Test-Check 'Reguła zapory Remote Desktop aktywna' {
    # Wystarczy, że choć jedna reguła RDP jest włączona
    [bool](Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayGroup -eq 'Remote Desktop' -and $_.Enabled -eq 'True' })
}
Test-Check 'Domain Admins w grupie RDP' {
    $rdpSID  = [System.Security.Principal.SecurityIdentifier]'S-1-5-32-555'
    $grpName = $rdpSID.Translate([System.Security.Principal.NTAccount]).Value.Split('\')[1]
    # Po dołączeniu do domeny przed restartem Net może nie widzieć konta domenowego;
    # sprawdzamy przez net localgroup jako fallback
    $members = Get-LocalGroupMember -Group $grpName -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Name
    if ($members -contains 'telemond.holding\Domain Admins') { return $true }
    # Fallback: net localgroup
    $netOut = & net localgroup $grpName 2>&1 | Out-String
    $netOut -match 'Domain Admins'
}

# 9.7 Domena
Test-Check 'Komputer w domenie telemond.holding' {
    $cs = Get-WmiObject Win32_ComputerSystem -ErrorAction SilentlyContinue
    $cs.PartOfDomain -and $cs.Domain -eq 'telemond.holding'
}

# 9.8 BitLocker
Test-Check 'BitLocker aktywny na C:' {
    $bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction SilentlyContinue
    $bl.ProtectionStatus -eq 'On' -or $bl.VolumeStatus -in 'FullyEncrypted','EncryptionInProgress'
}
Test-Check 'Protektor RecoveryPassword istnieje' {
    $bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction SilentlyContinue
    [bool]($bl.KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword')
}
Test-Check 'Protektor TPM istnieje' {
    $bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction SilentlyContinue
    [bool]($bl.KeyProtector | Where-Object KeyProtectorType -eq 'Tpm')
}

# ── Zapis raportu na pulpicie ──────────────────────────────────────────────────
$pass  = ($testResults | Where-Object Status -eq 'PASS').Count
$fail  = ($testResults | Where-Object Status -eq 'FAIL').Count
$total = $testResults.Count

# Próbujemy pulpit użytkownika IT, a jeśli go nie ma – pulpit bieżącego użytkownika
$desktopIT = "C:\Users\IT\Desktop"
$desktop    = if (Test-Path $desktopIT) { $desktopIT } else { [Environment]::GetFolderPath('Desktop') }
$reportPath = Join-Path $desktop "Weryfikacja_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

$lines  = @()
$lines += '=' * 56
$lines += "  RAPORT WERYFIKACJI WDROŻENIA  –  $env:COMPUTERNAME"
$lines += "  Data : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$lines += '=' * 56
$lines += ''
$lines += "  Wynik końcowy : $pass / $total PASS"
if ($fail -gt 0) { $lines += "  UWAGA         : $fail test(ów) zakończonych FAIL" }
$lines += ''
$lines += '-' * 56

foreach ($r in $testResults) {
    $icon = if ($r.Status -eq 'PASS') { '[+]' } else { '[!]' }
    $lines += "$icon $($r.Status.PadRight(4))  $($r.Test)"
    if ($r.Info) { $lines += "         Szczegóły: $($r.Info)" }
}

$lines += ''
$lines += '-' * 56
$lines += "  Transkrypt : $LogPath"
$lines += '=' * 56

$lines | Out-File -FilePath $reportPath -Encoding utf8 -Force
Write-Log "Raport zapisany: $reportPath" OK

# ══════════════════════════════════════════════════════════════════════════════
# PODSUMOWANIE
# ══════════════════════════════════════════════════════════════════════════════
Write-Log '══════════════════ PODSUMOWANIE ════════════════' INFO
Write-Log "  Log          : $LogPath"                        INFO
Write-Log "  Raport       : $reportPath"                     INFO
Write-Log "  Testy        : $pass/$total PASS | $fail FAIL"  $(if ($fail -gt 0) { 'WARN' } else { 'OK' })
if ($wingetFailed.Count -gt 0) {
    Write-Log "  Winget błędy : $($wingetFailed.Count)" WARN
}
Write-Log '  WYMAGANY RESTART (dołączenie do domeny).' WARN
Write-Log '════════════════════════════════════════════════' INFO

Stop-Transcript
