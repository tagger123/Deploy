#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    Skrypt wdrożeniowy – konfiguracja systemu, instalacja oprogramowania,
    dołączenie do domeny, włączenie RDP i szyfrowanie BitLocker.
.NOTES
    Wersja  : 2.3
    Autor   : Michał Sawczuk
    Data    : 2026-06-10
    Wymaga  : uprawnień administratora, dostępu do \\172.x.x.x
#>

# ── Transkrypt ────────────────────────────────────────────────────────────────
$LogPath = "C:\Windows\Temp\unattend_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $LogPath -Append -ErrorAction SilentlyContinue

# ── Funkcja logowania ─────────────────────────────────────────────────────────
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )
    $palette = @{ INFO = 'Cyan'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red' }
    Write-Host "[$Level] $Message" -ForegroundColor $palette[$Level]
}

# ── Hasła kont lokalnych – nigdy nie wygasają ─────────────────────────────────
Set-LocalUser -Name 'IT'   -PasswordNeverExpires $true
Set-LocalUser -Name 'help' -PasswordNeverExpires $true

# ══════════════════════════════════════════════════════════════════════════════
# 1. ZASILANIE I HIBERNACJA
# ══════════════════════════════════════════════════════════════════════════════
Write-Log 'Konfiguracja zarządzania energią...'

powercfg.exe /hibernate off                 # wyłącz hibernację
powercfg.exe /change monitor-timeout-ac 0   # wygaszacz: nigdy (zasilanie AC)
powercfg.exe /change monitor-timeout-dc 0   # wygaszacz: nigdy (bateria)
powercfg.exe /change standby-timeout-ac 0   # uśpienie: nigdy (AC)
powercfg.exe /change standby-timeout-dc 0   # uśpienie: nigdy (bateria)

Write-Log 'Wygaszanie ekranu → NIGDY.'  OK
Write-Log 'Hibernacja wyłączona.'       OK
Write-Log 'Uśpienie systemu → NIGDY.'  OK

# ══════════════════════════════════════════════════════════════════════════════
# 2. .NET FRAMEWORK 3.5
# ══════════════════════════════════════════════════════════════════════════════
Write-Log 'Instalowanie .NET Framework 3.5...'
try {
    Enable-WindowsOptionalFeature -Online -FeatureName 'NetFx3' -All -NoRestart | Out-Null
    Write-Log '.NET Framework 3.5 zainstalowany.' OK
}
catch {
    Write-Log ".NET Framework 3.5 – błąd instalacji: $_" WARN
}

# ══════════════════════════════════════════════════════════════════════════════
# 3. APLIKACJE WINGET
# ══════════════════════════════════════════════════════════════════════════════
# Identyfikatory pakietów z repozytorium winget (winget.run / aka.ms/winget).
$wingetApps = @(
    'Microsoft.DotNet.DesktopRuntime.8'
    'Adobe.Acrobat.Reader.64-bit'
    '7zip.7zip'
    'Microsoft.Teams'
    'Microsoft.Office'
)

[double]$complete  = 0
[double]$increment = 100.0 / $wingetApps.Count
$spinner      = @('|', '/', '-', '\')
$spinnerIndex = 0
$wingetFailed = [System.Collections.Generic.List[string]]::new()

foreach ($app in $wingetApps) {
    Write-Progress -Id 0 `
        -Activity    'Instalacja oprogramowania (Winget) – nie zamykaj okna.' `
        -Status      "Aktualnie: $app" `
        -PercentComplete ([Math]::Min([int]$complete, 100))

    $appLabel = $app.Trim()
    if ($appLabel.Length -gt 99) { $appLabel = $appLabel.Substring(0, 99) + '…' }

    # Uruchamiamy winget przez ProcessStartInfo – daje kontrolę nad buforami stdout/stderr.
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = 'winget.exe'
    $psi.Arguments              = "install --id `"$app`" --exact --silent --accept-package-agreements --accept-source-agreements --scope machine"
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi

    # Puste handlery zdarzeń – zapobiegają zapełnieniu buforów i zawieszeniu procesu.
    $action = { }
    Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -Action $action | Out-Null
    Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived  -Action $action | Out-Null

    $null = $process.Start()
    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()

    # Animacja spinnera co 250 ms, dopóki proces trwa.
    while (-not $process.HasExited) {
        $char = $spinner[$spinnerIndex]
        $spinnerIndex = ($spinnerIndex + 1) % $spinner.Count
        Write-Host -NoNewline "    [$char] [Winget] Instalowanie: $appLabel...`r"
        Start-Sleep -Milliseconds 250
    }
    Write-Host -NoNewline (" " * 110 + "`r")   # wyczyść linię spinnera

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
    Write-Log 'Aplikacje z niezerowym kodem wyjścia winget:' WARN
    $wingetFailed | ForEach-Object { Write-Log "  - $_" WARN }
}

# ══════════════════════════════════════════════════════════════════════════════
# 4a. NAV 2015
# ══════════════════════════════════════════════════════════════════════════════
Write-Log 'Uruchamianie instalacji NAV 2015 z sieci lokalnej...'
$navScriptPath = '\\172.20.0.71\Public\Deploy\Apps\NAV\nav2015.bat'

if (Test-Path -LiteralPath $navScriptPath) {
    Write-Log 'Znaleziono skrypt NAV. Uruchamianie...'
    try {
        $nav = Start-Process -FilePath 'cmd.exe' `
            -ArgumentList "/c `"$navScriptPath`"" `
            -NoNewWindow -Wait -PassThru -ErrorAction Stop

        if ($nav.ExitCode -eq 0) {
            Write-Log 'NAV 2015 zainstalowany pomyślnie.' OK
            # Kopiujemy plik konfiguracyjny klienta NAV do ProgramData.
            Copy-Item '\\172.20.0.71\Public\Deploy\Apps\NAV\ClientUserSettings.config' `
                -Destination 'C:\ProgramData\Microsoft\Microsoft Dynamics NAV\80\ClientUserSettings.config' `
                -Force
            Write-Log 'Konfiguracja NAV przeniesiona pomyślnie.' OK
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
    Write-Log "BŁĄD: Nie znaleziono ścieżki: $navScriptPath" ERROR
    Write-Log 'Sprawdź dostęp do udziału sieciowego przed ponownym uruchomieniem.' WARN
}

# ══════════════════════════════════════════════════════════════════════════════
# 4b. ANYDESK
# ══════════════════════════════════════════════════════════════════════════════
Write-Log 'Instalacja AnyDesk z sieci lokalnej...'
$anydeskPath = '\\172.20.0.71\Public\Deploy\Apps\Anydesk\AnyDeskClientTelemond.msi'

if (Test-Path -LiteralPath $anydeskPath) {
    Write-Log 'Znaleziono instalator AnyDesk. Uruchamianie...'
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
    Write-Log "BŁĄD: Nie znaleziono ścieżki: $anydeskPath" ERROR
    Write-Log 'Sprawdź dostęp do udziału sieciowego przed ponownym uruchomieniem.' WARN
}

# ══════════════════════════════════════════════════════════════════════════════
# 4c. TIGHTVNC
# ══════════════════════════════════════════════════════════════════════════════
Write-Log 'Instalacja TightVNC z sieci lokalnej...'
$tightvncPath = '\\172.20.0.71\Public\Deploy\Apps\Tight\tightvnc.msi'

if (Test-Path -LiteralPath $tightvncPath) {
    Write-Log 'Znaleziono instalator TightVNC. Uruchamianie...'
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
    Write-Log "BŁĄD: Nie znaleziono ścieżki: $tightvncPath" ERROR
    Write-Log 'Sprawdź dostęp do udziału sieciowego przed ponownym uruchomieniem.' WARN
}

# ══════════════════════════════════════════════════════════════════════════════
# 5. DOŁĄCZENIE DO DOMENY
# ══════════════════════════════════════════════════════════════════════════════
Write-Log 'Dołączanie do domeny telemond.holding...'
try {
    $domainCred = Get-Credential -Message 'Podaj konto z uprawnieniami do dołączenia do domeny telemond.holding:'
    Add-Computer -DomainName 'telemond.holding' -Credential $domainCred -ErrorAction Stop
    Write-Log 'Komputer dołączył do domeny. Wymagany restart.' OK
}
catch {
    Write-Log "Błąd przy dołączaniu do domeny: $_" ERROR
}

# ══════════════════════════════════════════════════════════════════════════════
# 6. RDP
# ══════════════════════════════════════════════════════════════════════════════
Write-Log 'Włączanie Remote Desktop (RDP)...'

# Zezwalamy na połączenia RDP (fDenyTSConnections = 0).
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
    -Name 'fDenyTSConnections' -Value 0

# Wymuszamy NLA (Network Level Authentication) dla zwiększenia bezpieczeństwa.
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
    -Name 'UserAuthentication' -Value 1

Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
Write-Log 'RDP włączone, reguła zapory aktywna.' OK

# Tłumaczymy SID S-1-5-32-555 na lokalną nazwę grupy (odpowiednik "Remote Desktop Users").
$rdpSID       = [System.Security.Principal.SecurityIdentifier]'S-1-5-32-555'
$rdpGroupName = $rdpSID.Translate([System.Security.Principal.NTAccount]).Value.Split('\')[1]

$accountsToAdd = @(
    'telemond.holding\Domain Admins'
    'telemond.holding\Enterprise Admins'
)

foreach ($account in $accountsToAdd) {
    try {
        $members = Get-LocalGroupMember -Group $rdpGroupName -ErrorAction Stop |
            Select-Object -ExpandProperty Name

        if ($members -contains $account) {
            Write-Log "$account już należy do grupy $rdpGroupName." INFO
        }
        else {
            Add-LocalGroupMember -Group $rdpGroupName -Member $account -ErrorAction Stop
            Write-Log "Dodano $account do grupy $rdpGroupName." OK
        }
    }
    catch {
        Write-Log "Nie dodano $account. Powód: $_" ERROR
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# 7. BITLOCKER
# ══════════════════════════════════════════════════════════════════════════════
$DriveLetter  = 'C:'
$Folder       = '\\172.20.0.71\Public\Deploy\BL\'
$IpConfigPath = Join-Path $Folder "Siec_$env:COMPUTERNAME.txt"
$BackupPath   = Join-Path $Folder "KluczOdzyskiwania_$env:COMPUTERNAME.txt"

# Zapisujemy ipconfig /all na udziale – przyda się przy diagnozie.
try {
    ipconfig /all | Out-File -FilePath $IpConfigPath -Encoding utf8 -Force
    Write-Log "Konfiguracja sieciowa zapisana: $IpConfigPath" OK
}
catch {
    Write-Log "Nie można zapisać konfiguracji sieciowej: $_" WARN
}

Write-Log 'Przygotowanie BitLocker...'
try {
    $tpm = Get-Tpm -ErrorAction Stop
    Write-Log "TPM – Present: $($tpm.TpmPresent) | Enabled: $($tpm.TpmEnabled) | Activated: $($tpm.TpmActivated)" INFO
}
catch {
    Write-Log "Błąd pobrania stanu TPM: $_" WARN
}

try {
    $blStatus = Get-BitLockerVolume -MountPoint $DriveLetter -ErrorAction Stop
    Write-Log "Stan BitLocker na $DriveLetter : $($blStatus.VolumeStatus)" INFO

    # Jeśli szyfrowanie jest już aktywne – wyłączamy i czyścimy przed ponownym włączeniem.
    if ($blStatus.VolumeStatus -in 'FullyEncrypted', 'EncryptionInProgress', 'EncryptionPaused', 'EncryptionSuspended') {
        Write-Log "BitLocker aktywny. Wyłączanie i czyszczenie..." INFO
        try {
            Write-Log "Wyłączanie BitLocker..." INFO
            manage-bde -off $DriveLetter 2>&1 | Out-Null

            $timeout = 0
            $maxWait = 240
            while ($timeout -lt $maxWait) {
                $statusOutput = manage-bde -status $DriveLetter 2>&1
                if ($statusOutput -match 'Fully Decrypted') {
                    Write-Log "BitLocker wyłączony – wolumin w pełni odszyfrowany." OK
                    break
                }
                Start-Sleep -Seconds 2
                $timeout += 2
                if ($timeout % 10 -eq 0) { Write-Host -NoNewline "." }
            }

            if ($timeout -ge $maxWait) {
                Write-Log "Timeout przy wyłączaniu BitLocker. Kontynuuję czyszczenie..." WARN
            }
            else {
                Write-Log "" INFO
            }

            Write-Log "Usuwanie wszystkich protektorów..." INFO
            manage-bde -protectors -delete $DriveLetter 2>&1 | Out-Null
            Write-Log "Protektory usunięte." OK
        }
        catch {
            Write-Log "Błąd przy wyłączaniu/czyszczeniu BitLocker: $_" WARN
        }
    }

    Write-Log "Włączanie szyfrowania BitLocker na $DriveLetter..." INFO
    try {
        # Próba 1: z -SkipHardwareTest (zalecane na VM i niektórych konfiguracjach).
        Enable-BitLocker -MountPoint $DriveLetter `
            -RecoveryPasswordProtector `
            -SkipHardwareTest `
            -ErrorAction Stop | Out-Null

        Write-Log "BitLocker włączony na $DriveLetter." OK
        Resume-BitLocker -MountPoint $DriveLetter -ErrorAction SilentlyContinue | Out-Null
        Add-BitLockerKeyProtector -MountPoint $DriveLetter -TpmProtector -ErrorAction SilentlyContinue | Out-Null
    }
    catch [System.Management.Automation.ParameterBindingException] {
        Write-Log "Błąd parametrów Enable-BitLocker: $_" ERROR
        Write-Log "Próba alternatywnego polecenia..." INFO

        try {
            # Próba 2: bez -SkipHardwareTest.
            Enable-BitLocker -MountPoint $DriveLetter `
                -RecoveryPasswordProtector `
                -ErrorAction Stop | Out-Null

            Write-Log "BitLocker włączony (bez -SkipHardwareTest)." OK
            Resume-BitLocker -MountPoint $DriveLetter -ErrorAction SilentlyContinue | Out-Null
            Add-BitLockerKeyProtector -MountPoint $DriveLetter -TpmProtector -ErrorAction SilentlyContinue | Out-Null
        }
        catch {
            Write-Log "Druga próba nie powiodła się: $_" ERROR
            Write-Log "Próba włączenia BitLocker poprzez manage-bde..." INFO

            try {
                # Próba 3 (fallback): manage-bde z linii poleceń.
                $result = & manage-bde -protectors -add $DriveLetter -rp 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Log "BitLocker włączony poprzez manage-bde." OK
                    Resume-BitLocker -MountPoint $DriveLetter -ErrorAction SilentlyContinue | Out-Null
                    & manage-bde -protectors -add C: -tpm
                }
                else {
                    Write-Log "manage-bde zwrócił kod: $LASTEXITCODE. Wyjście: $result" ERROR
                }
            }
            catch {
                Write-Log "Błąd manage-bde: $_" ERROR
            }
        }
    }
    catch {
        Write-Log "Błąd podczas włączania BitLocker: $_" ERROR
    }
}
catch {
    Write-Log "Nie można pobrać stanu BitLocker: $_" ERROR
}

# ── Eksport klucza odzyskiwania ───────────────────────────────────────────────
try {
    $blFinal = Get-BitLockerVolume -MountPoint $DriveLetter -ErrorAction Stop

    $recoveryProtector = $blFinal.KeyProtector |
        Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } |
        Select-Object -First 1

    if ($recoveryProtector) {
        $fileContent = @"
==================================================
KOPIA ZAPASOWA KLUCZA ODZYSKIWANIA BITLOCKER
==================================================
Data wygenerowania : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Nazwa komputera    : $env:COMPUTERNAME
Litera dysku       : $DriveLetter
Identyfikator ID   : $($recoveryProtector.KeyProtectorId)
Klucz odzyskiwania : $($recoveryProtector.RecoveryPassword)
==================================================
INSTRUKCJA: Przechowuj ten klucz w bezpiecznym miejscu!
UWAGA: Bez tego klucza, jeśli zapomnisz hasła do systemu,
       dysk będzie niedostępny.
==================================================
"@
        if (Test-Path -LiteralPath $Folder -ErrorAction SilentlyContinue) {
            try {
                $fileContent | Out-File -FilePath $BackupPath -Encoding utf8 -Force
                Write-Log "Klucz odzyskiwania zapisany: $BackupPath" OK
            }
            catch {
                Write-Log "OSTRZEŻENIE: Nie można zapisać klucza do folderu sieciowego: $_" WARN
                $LocalBackupPath = "C:\Windows\Panther\RecoveryKey_$env:COMPUTERNAME.txt"
                try {
                    mkdir -Path (Split-Path $LocalBackupPath) -ErrorAction SilentlyContinue | Out-Null
                    $fileContent | Out-File -FilePath $LocalBackupPath -Encoding utf8 -Force
                    Write-Log "Klucz zapisany lokalnie: $LocalBackupPath" WARN
                }
                catch {
                    Write-Log "KRYTYCZNE: Nie można zapisać klucza nigdzie: $_" ERROR
                }
            }
        }
        else {
            Write-Log "Folder $Folder niedostępny. Klucz zapisywany lokalnie..." WARN
            $LocalBackupPath = "C:\Windows\Panther\RecoveryKey_$env:COMPUTERNAME.txt"
            try {
                mkdir -Path (Split-Path $LocalBackupPath) -ErrorAction SilentlyContinue | Out-Null
                $fileContent | Out-File -FilePath $LocalBackupPath -Encoding utf8 -Force
                Write-Log "Klucz zapisany lokalnie: $LocalBackupPath" WARN
            }
            catch {
                Write-Log "KRYTYCZNE: Nie można zapisać klucza: $_" ERROR
            }
        }
    }
    else {
        Write-Log 'Nie znaleziono protektora RecoveryPassword w konfiguracji.' WARN
    }
}
catch {
    Write-Log "Błąd podczas przetwarzania klucza odzyskiwania: $_" ERROR
}

# Status końcowy BitLocker
try {
    $blFinal = Get-BitLockerVolume -MountPoint $DriveLetter -ErrorAction SilentlyContinue
    Write-Log "Finalny stan BitLocker: $($blFinal.VolumeStatus) / % przetworzenia: $($blFinal.EncryptionPercentage)%" INFO
}
catch { <# Cicho, jeśli BitLocker niedostępny #> }

# ══════════════════════════════════════════════════════════════════════════════
# 8. WERYFIKACJA – testy powdrożeniowe
# ══════════════════════════════════════════════════════════════════════════════
Write-Log '══════════════════════════════════════════' INFO
Write-Log '  Uruchamianie testów weryfikacyjnych...'    INFO
Write-Log '══════════════════════════════════════════' INFO

$testResults = [System.Collections.Generic.List[PSCustomObject]]::new()

function Test-Check {
    param(
        [string]$Name,
        [scriptblock]$Test
    )
    try {
        $ok = & $Test
        $status = if ($ok) { 'PASS' } else { 'FAIL' }
        $msg    = ''
    }
    catch {
        $status = 'FAIL'
        $msg    = $_.ToString()
    }
    $script:testResults.Add([PSCustomObject]@{
        Test   = $Name
        Status = $status
        Info   = $msg
    })
    $level = if ($status -eq 'PASS') { 'OK' } else { 'WARN' }
    Write-Log "  [$status] $Name$(if ($msg) { " – $msg" })" $level
}

# 8.1 Konta lokalne
Test-Check 'Konto IT istnieje' {
    [bool](Get-LocalUser -Name 'IT' -ErrorAction SilentlyContinue)
}
Test-Check 'Konto help istnieje' {
    [bool](Get-LocalUser -Name 'help' -ErrorAction SilentlyContinue)
}
Test-Check 'Hasło konta IT nie wygasa' {
    (Get-LocalUser -Name 'IT').PasswordNeverExpires
}
Test-Check 'Hasło konta help nie wygasa' {
    (Get-LocalUser -Name 'help').PasswordNeverExpires
}

# 8.2 Zasilanie
Test-Check 'Hibernacja wyłączona' {
    $raw = powercfg /query SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE 2>&1 | Out-String
    $raw -match 'Current AC Power Setting Index: 0x00000000' -and
    $raw -match 'Current DC Power Setting Index: 0x00000000'
}
Test-Check 'Monitor timeout AC = 0 (nigdy)' {
    $raw = powercfg /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 2>&1 | Out-String
    $raw -match 'Current AC Power Setting Index: 0x00000000'
}

# 8.3 .NET Framework 3.5
Test-Check '.NET Framework 3.5 włączony' {
    $f = Get-WindowsOptionalFeature -Online -FeatureName 'NetFx3' -ErrorAction SilentlyContinue
    $f.State -eq 'Enabled'
}

# 8.4 Winget – zainstalowane aplikacje
$wingetCheckApps = @{
    '7-Zip'         = { Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{*}' }
    'AnyDesk'       = { [bool](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object DisplayName -like '*AnyDesk*') }
    'TightVNC'      = { [bool](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object DisplayName -like '*TightVNC*') }
    'Adobe Acrobat' = { [bool](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object DisplayName -like '*Adobe Acrobat*') }
    'MS Teams'      = { [bool](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object DisplayName -like '*Teams*') }
}
foreach ($appName in $wingetCheckApps.Keys) {
    Test-Check "Zainstalowano: $appName" $wingetCheckApps[$appName]
}

# 8.5 NAV 2015 – plik konfiguracyjny klienta
Test-Check 'NAV 2015 – ClientUserSettings.config istnieje' {
    Test-Path 'C:\ProgramData\Microsoft\Microsoft Dynamics NAV\80\ClientUserSettings.config'
}

# 8.6 RDP
Test-Check 'RDP włączone (rejestr)' {
    $v = (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server').fDenyTSConnections
    $v -eq 0
}
Test-Check 'NLA włączone (rejestr)' {
    $v = (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp').UserAuthentication
    $v -eq 1
}
Test-Check 'Reguła zapory Remote Desktop aktywna' {
    $rule = Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue |
        Where-Object Enabled -eq 'True'
    [bool]$rule
}
Test-Check 'Domain Admins w grupie RDP' {
    $rdpSID  = [System.Security.Principal.SecurityIdentifier]'S-1-5-32-555'
    $grpName = $rdpSID.Translate([System.Security.Principal.NTAccount]).Value.Split('\')[1]
    $members = Get-LocalGroupMember -Group $grpName -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Name
    $members -contains 'telemond.holding\Domain Admins'
}

# 8.7 Domena
Test-Check 'Komputer w domenie telemond.holding' {
    (Get-WmiObject Win32_ComputerSystem).PartOfDomain -and
    (Get-WmiObject Win32_ComputerSystem).Domain -eq 'telemond.holding'
}

# 8.8 BitLocker
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

$reportPath = "C:\Users\IT\Desktop\Weryfikacja_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

$reportLines = @()
$reportLines += "=" * 54
$reportLines += "  RAPORT WERYFIKACJI WDROŻENIA – $env:COMPUTERNAME"
$reportLines += "  Data: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$reportLines += "=" * 54
$reportLines += ""
$reportLines += "  Wynik: $pass/$total testów zakończonych PASS"
if ($fail -gt 0) {
    $reportLines += "  UWAGA: $fail test(ów) zakończonych FAIL – sprawdź poniżej."
}
$reportLines += ""
$reportLines += "-" * 54

foreach ($r in $testResults) {
    $icon = if ($r.Status -eq 'PASS') { '[+]' } else { '[!]' }
    $line = "$icon $($r.Status.PadRight(4))  $($r.Test)"
    if ($r.Info) { $line += "`n         Szczegóły: $($r.Info)" }
    $reportLines += $line
}

$reportLines += ""
$reportLines += "-" * 54
$reportLines += "  Log transkryptu: $LogPath"
$reportLines += "=" * 54

$reportLines | Out-File -FilePath $reportPath -Encoding utf8 -Force
Write-Log "Raport weryfikacji zapisany: $reportPath" OK

# ══════════════════════════════════════════════════════════════════════════════
# PODSUMOWANIE
# ══════════════════════════════════════════════════════════════════════════════
Write-Log '==========================================' INFO
Write-Log '  Skrypt wdrożeniowy zakończony.'           INFO
Write-Log "  Log: $LogPath"                            INFO
Write-Log "  Weryfikacja: $pass/$total PASS  |  $fail FAIL"  $(if ($fail -gt 0) { 'WARN' } else { 'OK' })
if ($wingetFailed.Count -gt 0) {
    Write-Log "  Aplikacje winget z błędem: $($wingetFailed.Count)" WARN
}
Write-Log '  WYMAGANY RESTART (dołączenie do domeny).' WARN
Write-Log '==========================================' INFO

Stop-Transcript
