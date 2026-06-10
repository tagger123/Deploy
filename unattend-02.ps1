#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    Skrypt wdrożeniowy – konfiguracja systemu, instalacja oprogramowania,
    dołączenie do domeny, włączenie RDP i szyfrowanie BitLocker.
.NOTES
    Wersja  : 2.2
    Autor   : Michał Sawczuk
    Data    : 2024-06-15
    Wymaga  : uprawnień administratora, dostępu do \\172.x.x.x
#>

# Transkrypt / log
$LogPath = "C:\Windows\Temp\unattend_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $LogPath -Append -ErrorAction SilentlyContinue

# Funkcja pomocnicza
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
# hasło nigdy nie wygasające dla kont IT i help
Set-LocalUser -Name 'IT' -PasswordNeverExpires $true
Set-LocalUser -Name 'help' -PasswordNeverExpires $true
# 1. ZASILANIE I HIBERNACJA
Write-Log 'Konfiguracja zarządzania energią...'
# Wyłączamy hibernację i ustawiamy brak wygaszania ekranu oraz uśpienia
powercfg.exe /hibernate off
# Ustawienia wygaszania ekranu i uśpienia na "nigdy" (0)
powercfg.exe /change monitor-timeout-ac 0
# Dla zasilania bateryjnego (jeśli dotyczy), również ustawiamy na "nigdy"
powercfg.exe /change monitor-timeout-dc 0
# Ustawienia uśpienia na "nigdy" (0)
powercfg.exe /change standby-timeout-ac 0
# Dla zasilania bateryjnego (jeśli dotyczy), również ustawiamy na "nigdy"
powercfg.exe /change standby-timeout-dc 0

Write-Log 'Wygaszanie ekranu → NIGDY.'        OK
Write-Log 'Hibernacja wyłączona.'             OK
Write-Log 'Uśpienie systemu → NIGDY.'         OK

# 2. .NET FRAMEWORK 3.5
Write-Log 'Instalowanie .NET Framework 3.5...'
try {
    # -Online: modyfikacja bieżącego systemu -FeatureName: nazwa funkcji -All: wszystkie zależności -NoRestart: bez automatycznego restartu
    Enable-WindowsOptionalFeature -Online -FeatureName 'NetFx3' -All -NoRestart |
    # Out-Null, bo domyślnie zwraca obiekt z informacjami o instalacji, ale nie jest potrzebny w logu
        Out-Null
    Write-Log '.NET Framework 3.5 zainstalowany.' OK
}
catch {
    Write-Log ".NET Framework 3.5 – błąd instalacji: $_" WARN
}

# 3. APLIKACJE WINGET
# Lista aplikacji do zainstalowania przez winget. Używamy identyfikatorów pakietów z oficjalnego repozytorium Microsoft.
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
# Przygotowanie procesu do uruchomienia winget z odpowiednimi argumentami. Używamy ProcessStartInfo, aby lepiej kontrolować wyjście i błędy.
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    # Używamy winget.exe
    $psi.FileName               = 'winget.exe'
    # Argumenty do instalacji: --id z nazwą pakietu, --exact dla dokładnego dopasowania, --silent dla cichej instalacji, --accept-package-agreements i --accept-source-agreements dla automatycznej akceptacji umów, --scope machine dla instalacji systemowej
    $psi.Arguments              = "install --id `"$app`" --exact --silent --accept-package-agreements --accept-source-agreements --scope machine"
    # Ustawienia procesu: bez użycia powłoki, bez okna, przekierowanie standardowego wyjścia i błędów, aby móc je odczytać i ewentualnie zalogować.
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi

    # Dodajemy puste akcje, aby natychmiast utylizować dane z bufora
    $action = { }
    # Rejestrujemy zdarzenia dla standardowego wyjścia i błędów, aby uniknąć zapełnienia bufora i potencjalnego zawieszenia procesu. Nie zapisujemy tych danych, ale można je rozbudować o logowanie, jeśli zajdzie taka potrzeba.
    Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -Action $action | Out-Null
    # Rejestrujemy zdarzenie dla błędów, aby natychmiast utylizować dane z bufora błędów. Podobnie jak wyżej, można rozbudować o logowanie.
    Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -Action $action | Out-Null

    $null = $process.Start()
    # Rozpoczynamy asynchroniczne odczytywanie standardowego wyjścia i błędów, aby uniknąć zapełnienia bufora. Dane są odczytywane, ale nie są zapisywane w logu, co pozwala na płynne działanie procesu.
    $process.BeginOutputReadLine()
    # Rozpoczynamy asynchroniczne odczytywanie błędów, aby uniknąć zapełnienia bufora błędów. Dane są odczytywane, ale nie są zapisywane w logu, co pozwala na płynne działanie procesu.
    $process.BeginErrorReadLine()
    # Pętla, która co 250 ms aktualizuje animację spinnera i status instalacji, dopóki proces nie zakończy działania. Używamy Write-Host z -NoNewline i `r, aby nadpisać linię w konsoli, tworząc efekt animacji.
    while (-not $process.HasExited) {
        $char = $spinner[$spinnerIndex]
        $spinnerIndex = ($spinnerIndex + 1) % $spinner.Count
        Write-Host -NoNewline "    [$char] [Winget] Instalowanie: $appLabel...`r"
        Start-Sleep -Milliseconds 250
    }
    # Po zakończeniu procesu, nadpisujemy linię, aby usunąć spinner i pozostawić tylko informację o zakończeniu instalacji. Używamy spacji, aby wyczyścić pozostałości po poprzednim komunikacie.
    Write-Host -NoNewline (" " * 110 + "`r")
    # Sprawdzamy kod wyjścia procesu, aby określić, czy instalacja zakończyła się sukcesem (0) czy błędem (niezerowy). Logujemy odpowiedni komunikat i w przypadku błędu dodajemy aplikację do listy nieudanych instalacji.
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
# Po zakończeniu wszystkich instalacji, jeśli są jakieś błędy, wypisujemy je w logu. Używamy Write-Log z poziomem WARN, aby wyróżnić te informacje.
if ($wingetFailed.Count -gt 0) {
    Write-Log 'Aplikacje z niezerowym kodem wyjścia winget:' WARN
    $wingetFailed | ForEach-Object { Write-Log "  - $_" WARN }
}

# 4. NAV 2015
Write-Log 'Uruchamianie instalacji NAV 2015 z sieci lokalnej...'
$navScriptPath = '\\172.20.0.71\Public\Deploy\Apps\NAV\nav2015.bat'
# Sprawdzamy, czy skrypt instalacyjny NAV istnieje na udziale sieciowym. Jeśli tak, uruchamiamy go i czekamy na zakończenie. Po zakończeniu sprawdzamy kod wyjścia, aby potwierdzić sukces instalacji. W przypadku sukcesu, kopiujemy plik konfiguracyjny do docelowej lokalizacji. Jeśli skrypt nie zostanie znaleziony lub wystąpi błąd podczas instalacji, logujemy odpowiednie komunikaty.
if (Test-Path -LiteralPath $navScriptPath) {
    Write-Log 'Znaleziono skrypt NAV. Uruchamianie...'
    try {
        # Uruchamiamy skrypt NAV w trybie cichym, bez nowego okna, i czekamy na jego zakończenie. Przekazujemy argumenty do cmd.exe, aby wykonać skrypt .bat. Używamy -PassThru, aby uzyskać obiekt procesu i móc sprawdzić jego kod wyjścia.
        $nav = Start-Process -FilePath 'cmd.exe' `
            -ArgumentList "/c `"$navScriptPath`"" `
            -NoNewWindow -Wait -PassThru -ErrorAction Stop

        if ($nav.ExitCode -eq 0) {
            Write-Log 'NAV 2015 zainstalowany pomyślnie.' OK
            # Po pomyślnej instalacji, kopiujemy plik konfiguracyjny z udziału sieciowego do docelowej lokalizacji. Używamy -Force, aby nadpisać istniejący plik, jeśli już tam jest. Logujemy sukces tej operacji.
            Copy-Item '\\172.20.0.71\Public\Deploy\Apps\NAV\ClientUserSettings.config' -Destination 'C:\ProgramData\Microsoft\Microsoft Dynamics NAV\80\ClientUserSettings.config' -Force
            Write-Log 'Konfiguracja przeniesiona pomyślnie.' OK
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
# 4. ANYDESK
Write-Log 'Instalacja AnyDesk z Sieci lokalnej...'
$anydeskPath = '\\172.20.0.71\Public\Deploy\Apps\Anydesk\AnyDeskClientTelemond.msi'
# Sprawdzamy, czy instalator AnyDesk istnieje na udziale sieciowym. Jeśli tak, uruchamiamy go za pomocą msiexec.exe z odpowiednimi argumentami do cichej instalacji. Po zakończeniu sprawdzamy kod wyjścia, aby potwierdzić sukces instalacji. Jeśli instalator nie zostanie znaleziony lub wystąpi błąd podczas instalacji, logujemy odpowiednie komunikaty.
if (Test-Path -LiteralPath $anydeskPath) {
    Write-Log 'Znaleziono instalator AnyDesk. Uruchamianie...'
    try {
        # Uruchamiamy instalator AnyDesk za pomocą msiexec.exe, przekazując argumenty do cichej instalacji (/qn) i bez automatycznego restartu (/norestart). Używamy -PassThru, aby uzyskać obiekt procesu i móc sprawdzić jego kod wyjścia.
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

# 4. TightVNC
Write-Log 'Instalacja TightVNC z Sieci lokalnej...'
$tightvncPath = '\\172.20.0.71\Public\Deploy\Apps\Tight\tightvnc.msi'
# Sprawdzamy, czy instalator TightVNC istnieje na udziale sieciowym. Jeśli tak, uruchamiamy go za pomocą msiexec.exe z odpowiednimi argumentami do cichej instalacji. Po zakończeniu sprawdzamy kod wyjścia, aby potwierdzić sukces instalacji. Jeśli instalator nie zostanie znaleziony lub wystąpi błąd podczas instalacji, logujemy odpowiednie komunikaty.
if (Test-Path -LiteralPath $tightvncPath) {
    Write-Log 'Znaleziono instalator TightVNC. Uruchamianie...'
    try {
        # Uruchamiamy instalator TightVNC za pomocą msiexec.exe, przekazując argumenty do cichej instalacji (/qn) i bez automatycznego restartu (/norestart). Używamy -PassThru, aby uzyskać obiekt procesu i móc sprawdzić jego kod wyjścia.
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
# 5. DOŁĄCZENIE DO DOMENY
Write-Log 'Dołączanie do domeny telemond.holding...'
try {
    # Pobieramy poświadczenia od użytkownika, który ma uprawnienia do dołączenia komputera do domeny. Używamy Get-Credential, aby wyświetlić okno dialogowe z prośbą o podanie nazwy użytkownika i hasła. Komunikat w oknie dialogowym informuje, że konto powinno mieć odpowiednie uprawnienia do dołączenia do domeny telemond.holding.
    $domainCred = Get-Credential -Message 'Podaj konto z uprawnieniami do dołączenia do domeny telemond.holding:'
    # Używamy cmdletu Add-Computer, aby dołączyć komputer do domeny. Przekazujemy nazwę domeny, poświadczenia oraz ustawiamy ErrorAction na Stop, aby w przypadku błędu przechwycić go w bloku catch. Po pomyślnym dołączeniu, logujemy sukces i informujemy o konieczności restartu.
    Add-Computer -DomainName 'telemond.holding' -Credential $domainCred -ErrorAction Stop
    Write-Log 'Komputer dołączył do domeny. Wymagany restart.' OK
}
catch {
    Write-Log "Błąd przy dołączaniu do domeny: $_" ERROR
}

# 6. RDP
Write-Log 'Włączanie Remote Desktop (RDP)...'
# Ustawiamy w rejestrze, aby zezwolić na połączenia RDP i wymusić uwierzytelnianie na poziomie sieci (NLA). Następnie włączamy reguły zapory dla Remote Desktop. Logujemy sukces tej operacji.
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
    -Name 'fDenyTSConnections' -Value 0
# Ustawiamy w rejestrze, aby wymusić uwierzytelnianie na poziomie sieci (NLA) dla połączeń RDP. To zwiększa bezpieczeństwo, wymagając, aby użytkownicy uwierzytelniali się przed nawiązaniem sesji RDP.
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
    -Name 'UserAuthentication' -Value 1
# Włączamy reguły zapory dla grupy 'Remote Desktop', aby umożliwić połączenia RDP. Używamy -ErrorAction SilentlyContinue, aby uniknąć błędów, jeśli reguły już są włączone.
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
Write-Log 'RDP włączone, reguła zapory aktywna.' OK
# Dodajemy grupy 'Domain Admins' i 'Enterprise Admins' z domeny telemond.holding do lokalnej grupy 'Remote Desktop Users', aby członkowie tych grup mieli prawo do łączenia się przez RDP. Najpierw tłumaczymy SID grupy 'Remote Desktop Users' na nazwę, a następnie sprawdzamy, czy każdy z kont już jest członkiem tej grupy. Jeśli nie, dodajemy je i logujemy odpowiednie komunikaty.
$rdpSID       = [System.Security.Principal.SecurityIdentifier]'S-1-5-32-555'
$rdpGroupName = $rdpSID.Translate([System.Security.Principal.NTAccount]).Value.Split('\')[1]
# Lista kont do dodania do grupy RDP. Używamy formatu 'domena\grupa', aby jednoznacznie określić, które grupy z domeny telemond.holding mają być dodane do lokalnej grupy 'Remote Desktop Users'.
$accountsToAdd = @(
    'telemond.holding\Domain Admins'
    'telemond.holding\Enterprise Admins'
)
# Iterujemy przez listę kont, sprawdzając, czy każde z nich jest już członkiem grupy RDP. Jeśli tak, logujemy informację, że konto już należy do grupy. Jeśli nie, próbujemy dodać konto do grupy i logujemy sukces lub błąd tej operacji.
foreach ($account in $accountsToAdd) {
    try {
        # Pobieramy aktualnych członków grupy RDP i sprawdzamy, czy konto już jest członkiem tej grupy. Używamy Get-LocalGroupMember, aby uzyskać listę członków grupy, a następnie Select-Object -ExpandProperty Name, aby uzyskać tylko nazwy kont.
        $members = Get-LocalGroupMember -Group $rdpGroupName -ErrorAction Stop |
            Select-Object -ExpandProperty Name
        # Sprawdzamy, czy konto już jest członkiem grupy RDP. Jeśli tak, logujemy informację, że konto już należy do grupy. Jeśli nie, dodajemy konto do grupy i logujemy sukces tej operacji.
        if ($members -contains $account) {
            Write-Log "$account już należy do grupy $rdpGroupName." INFO
        }
        # Jeśli konto nie jest członkiem grupy RDP, próbujemy je dodać. Używamy Add-LocalGroupMember, aby dodać konto do grupy, i ustawiamy -ErrorAction Stop, aby w przypadku błędu przechwycić go w bloku catch. Po pomyślnym dodaniu, logujemy sukces tej operacji.
        else {
            Add-LocalGroupMember -Group $rdpGroupName -Member $account -ErrorAction Stop
            Write-Log "Dodano $account do grupy $rdpGroupName." OK
        }
    }
    catch {
        Write-Log "Nie dodano $account. Powód: $_" ERROR
    }
}

# 7. BITLOCKER
$DriveLetter  = 'C:'
$Folder       = '\\172.20.0.71\Public\Deploy\BL\'
$IpConfigPath = Join-Path $Folder "Siec_$env:COMPUTERNAME.txt"
$BackupPath   = Join-Path $Folder "KluczOdzyskiwania_$env:COMPUTERNAME.txt"
# Zapisujemy konfigurację sieciową do pliku tekstowego na udziale sieciowym. Używamy Out-File z kodowaniem UTF-8, aby zapewnić poprawne zapisanie polskich znaków. W przypadku błędu podczas zapisywania, logujemy odpowiedni komunikat.
try {
    ipconfig /all | Out-File -FilePath $IpConfigPath -Encoding utf8 -Force
    Write-Log "Konfiguracja sieciowa zapisana: $IpConfigPath" OK
}
catch {
    Write-Log "Nie można zapisać konfiguracji sieciowej: $_" WARN
}

Write-Log 'Przygotowanie BitLocker...'
try {
    # Pobieramy informacje o TPM (Trusted Platform Module) za pomocą Get-Tpm. Jeśli TPM jest obecny, logujemy jego stan (czy jest włączony i aktywowany). W przypadku błędu podczas pobierania informacji o TPM, logujemy odpowiedni komunikat.
    $tpm = Get-Tpm -ErrorAction Stop
    Write-Log "TPM – Present: $($tpm.TpmPresent) | Enabled: $($tpm.TpmEnabled) | Activated: $($tpm.TpmActivated)" INFO
}
catch {
    Write-Log "Błąd pobrania stanu TPM: $_" WARN
}

try {
    # Pobieramy stan BitLocker dla głównego dysku systemowego (C:). Logujemy aktualny stan woluminu. Jeśli wolumin jest w stanie 'FullyEncrypted', 'EncryptionInProgress', 'EncryptionPaused' lub 'EncryptionSuspended', oznacza to, że BitLocker jest aktywny i musimy go wyłączyć oraz oczyścić przed ponownym włączeniem. W przypadku błędu podczas pobierania stanu BitLocker, logujemy odpowiedni komunikat.
    $blStatus = Get-BitLockerVolume -MountPoint $DriveLetter -ErrorAction Stop
    Write-Log "Stan BitLocker na $DriveLetter : $($blStatus.VolumeStatus)" INFO
    if ($blStatus.VolumeStatus -in 'FullyEncrypted', 'EncryptionInProgress', 'EncryptionPaused', 'EncryptionSuspended') {
        Write-Log "BitLocker aktywny. Wyłączanie i czyszczenie..." INFO
        # Jeśli BitLocker jest aktywny, najpierw go wyłączamy, a następnie usuwamy wszystkie protektory, aby mieć czystą konfigurację przed ponownym włączeniem. Używamy manage-bde -off do wyłączenia BitLocker, a następnie monitorujemy proces odszyfrowywania, sprawdzając status co 2 sekundy. Jeśli odszyfrowanie nie zakończy się w ciągu 240 sekund, logujemy ostrzeżenie o timeoutie, ale kontynuujemy proces czyszczenia. Po wyłączeniu, używamy manage-bde -protectors -delete do usunięcia wszystkich protektorów z woluminu. W przypadku błędu podczas tego procesu, logujemy odpowiedni komunikat.
        try {
            Write-Log "Wyłączanie BitLocker..." INFO
            manage-bde -off $DriveLetter 2>&1 | Out-Null
            
            $timeout = 0
            $maxWait = 240
            while ($timeout -lt $maxWait) {
                # Sprawdzamy status BitLocker, aby zobaczyć, czy odszyfrowywanie się zakończyło. Jeśli status zawiera 'Fully Decrypted', oznacza to, że wolumin jest w pełni odszyfrowany i możemy przerwać pętlę. Jeśli nie, czekamy 2 sekundy i sprawdzamy ponownie. Co 10 sekund, wypisujemy kropkę, aby pokazać postęp. Jeśli po 240 sekundach odszyfrowanie nadal nie zakończyło się, logujemy ostrzeżenie o timeoutie.
                $statusOutput = manage-bde -status $DriveLetter 2>&1
                if ($statusOutput -match 'Fully Decrypted') {
                    Write-Log "BitLocker wyłączony - wolumin w pełni odszyfrowany." OK
                    break
                }
                Start-Sleep -Seconds 2
                $timeout += 2
                if ($timeout % 10 -eq 0) {
                    Write-Host -NoNewline "."
                }
            }
            
            if ($timeout -ge $maxWait) {
                Write-Log "Timeout przy wyłączaniu BitLocker. Kontynuuję czyszczenie..." WARN
            }
            else {
                Write-Log "" INFO
            }
            
            Write-Log "Usuwanie wszystkich protectorów..." INFO
            manage-bde -protectors -delete $DriveLetter 2>&1 | Out-Null
            Write-Log "Protektory usunięte." OK
        }
        catch {
            Write-Log "Błąd przy wyłączaniu/czyszczeniu BitLocker: $_" WARN
        }
    }
    
    Write-Log "Włączanie szyfrowania BitLocker na $DriveLetter..." INFO
    # Próba włączenia BitLocker z opcją skip hardware test, która jest często wymagana na maszynach wirtualnych lub niektórych konfiguracjach sprzętowych. Jeśli ta opcja powoduje błąd, próbujemy ponownie bez niej. Jeśli nadal występuje błąd, próbujemy użyć narzędzia manage-bde z linii poleceń jako ostateczność. Logujemy odpowiednie komunikaty na każdym etapie tego procesu.
    try {
        # Pierwsza próba: Enable-BitLocker z opcją -SkipHardwareTest, która jest często wymagana na maszynach wirtualnych lub niektórych konfiguracjach sprzętowych. Używamy -RecoveryPasswordProtector, aby dodać protektor hasłem numerycznym, i -ErrorAction Stop, aby w przypadku błędu przechwycić go w bloku catch. Po pomyślnym włączeniu, logujemy sukces tej operacji.
        Enable-BitLocker -MountPoint $DriveLetter `
            -RecoveryPasswordProtector `
            -SkipHardwareTest `
            -ErrorAction Stop | Out-Null
        
        Write-Log "BitLocker włączony na $DriveLetter." OK
        # Po włączeniu BitLocker, próbujemy wznowić szyfrowanie, aby rozpocząć proces szyfrowania. Używamy Resume-BitLocker, aby wznowić szyfrowanie, i ustawiamy -ErrorAction SilentlyContinue, aby uniknąć błędów, jeśli szyfrowanie już jest aktywne lub jeśli wystąpi inny problem. Logujemy odpowiedni komunikat w przypadku sukcesu.
        Resume-BitLocker -MountPoint $DriveLetter -ErrorAction SilentlyContinue | Out-Null
        Add-BitLockerKeyProtector -MountPoint $DriveLetter -TpmProtector -ErrorAction SilentlyContinue | Out-Null
    }
    # Jeśli wystąpi błąd związany z parametrami (np. opcja -SkipHardwareTest nie jest obsługiwana na tej maszynie), przechwytujemy ten konkretny wyjątek i próbujemy ponownie bez tej opcji. Jeśli nadal występuje błąd, próbujemy użyć narzędzia manage-bde z linii poleceń jako ostateczność. Logujemy odpowiednie komunikaty na każdym etapie tego procesu.
    catch [System.Management.Automation.ParameterBindingException] {
        Write-Log "Błąd parametrów Enable-BitLocker: $_" ERROR
        Write-Log "Próba alternatywnego polecenia..." INFO
        
        try {
            # Druga próba: Enable-BitLocker bez opcji -SkipHardwareTest. Używamy tych samych parametrów co wcześniej, ale bez tej opcji. Po pomyślnym włączeniu, logujemy sukces tej operacji i próbujemy wznowić szyfrowanie.
            Enable-BitLocker -MountPoint $DriveLetter `
                -RecoveryPasswordProtector `
                -ErrorAction Stop | Out-Null
                
            Write-Log "BitLocker włączony (bez skipa hardware test)." OK
            # Po włączeniu BitLocker, próbujemy wznowić szyfrowanie, aby rozpocząć proces szyfrowania. Używamy Resume-BitLocker, aby wznowić szyfrowanie, i ustawiamy -ErrorAction SilentlyContinue, aby uniknąć błędów, jeśli szyfrowanie już jest aktywne lub jeśli wystąpi inny problem. Logujemy odpowiedni komunikat w przypadku sukcesu.
            Resume-BitLocker -MountPoint $DriveLetter -ErrorAction SilentlyContinue | Out-Null
            Add-BitLockerKeyProtector -MountPoint $DriveLetter -TpmProtector -ErrorAction SilentlyContinue | Out-Null
        }
        catch {
            Write-Log "Druga próba nie powiodła się: $_" ERROR
            
            Write-Log "Próba włączenia BitLocker poprzez manage-bde..." INFO
            # Ostateczna próba: użycie narzędzia manage-bde z linii poleceń. Używamy manage-bde -protectors -add, aby dodać protektor hasłem numerycznym, i przekierowujemy standardowe wyjście i błędy, aby móc je odczytać i zalogować. Po pomyślnym włączeniu, logujemy sukces tej operacji i próbujemy wznowić szyfrowanie.
            try {
                # Używamy manage-bde -protectors -add, aby dodać protektor hasłem numerycznym do woluminu. Przekierowujemy standardowe wyjście i błędy, aby móc je odczytać i zalogować. Po pomyślnym włączeniu, logujemy sukces tej operacji i próbujemy wznowić szyfrowanie.
                $result = & manage-bde -protectors -add $DriveLetter -rp 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Log "BitLocker włączony poprzez manage-bde." OK
                    # Po włączeniu BitLocker, próbujemy wznowić szyfrowanie, aby rozpocząć proces szyfrowania. Używamy Resume-BitLocker, aby wznowić szyfrowanie, i ustawiamy -ErrorAction SilentlyContinue, aby uniknąć błędów, jeśli szyfrowanie już jest aktywne lub jeśli wystąpi inny problem. Logujemy odpowiedni komunikat w przypadku sukcesu.
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
 
# Eksport klucza odzyskiwania
# Po włączeniu BitLocker, próbujemy pobrać informacje o woluminie, aby znaleźć protektor hasłem numerycznym (RecoveryPassword). Jeśli znajdziemy ten protektor, tworzymy zawartość pliku tekstowego z kluczem odzyskiwania i informacjami o komputerze. Następnie próbujemy zapisać ten plik na udziale sieciowym. Jeśli zapis się nie powiedzie (np. z powodu braku dostępu do udziału), logujemy ostrzeżenie i próbujemy zapisać klucz lokalnie na dysku C: w folderze Windows\Panther. Logujemy odpowiednie komunikaty na każdym etapie tego procesu.
try {
    $blFinal = Get-BitLockerVolume -MountPoint $DriveLetter -ErrorAction Stop
    
    # Szukamy protektora typu 'RecoveryPassword', który zawiera klucz odzyskiwania w formie hasła numerycznego. Używamy Where-Object, aby przefiltrować listę protektorów i Select-Object -First 1, aby wziąć tylko pierwszy znaleziony protektor tego typu. Jeśli taki protektor zostanie znaleziony, przechodzimy do tworzenia zawartości pliku z kluczem odzyskiwania.
    $recoveryProtector = $blFinal.KeyProtector | Where-Object {
        $_.KeyProtectorType -eq 'RecoveryPassword'
    } | Select-Object -First 1
    
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
        # Próba zapisania klucza odzyskiwania na udziale sieciowym. Używamy Out-File z kodowaniem UTF-8, aby zapewnić poprawne zapisanie polskich znaków. Jeśli zapis się nie powiedzie (np. z powodu braku dostępu do udziału), logujemy ostrzeżenie i próbujemy zapisać klucz lokalnie na dysku C: w folderze Windows\Panther. Logujemy odpowiednie komunikaty na każdym etapie tego procesu.
        if (Test-Path -LiteralPath $Folder -ErrorAction SilentlyContinue) {
            try {
                $fileContent | Out-File -FilePath $BackupPath -Encoding utf8 -Force
                Write-Log "Klucz odzyskiwania zapisany: $BackupPath" OK
            }
            catch {
                Write-Log "OSTRZEŻENIE: Nie można zapisać klucza do folderu sieciowego: $_" WARN
                # Fallback: spróbuj zapisać lokalnie
                $LocalBackupPath = "C:\Windows\Panther\RecoveryKey_$env:COMPUTERNAME.txt"
                # Próba zapisania klucza odzyskiwania lokalnie na dysku C: w folderze Windows\Panther. Używamy Out-File z kodowaniem UTF-8, aby zapewnić poprawne zapisanie polskich znaków. W przypadku błędu podczas zapisywania, logujemy odpowiedni komunikat.
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
            # Tworzymy katalog docelowy, jeśli nie istnieje, a następnie zapisujemy klucz odzyskiwania do lokalnego pliku tekstowego. Używamy Out-File z kodowaniem UTF-8, aby zapewnić poprawne zapisanie polskich znaków. Logujemy sukces tej operacji.
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

# Status BitLocker na koniec
try {
    $blFinal = Get-BitLockerVolume -MountPoint $DriveLetter -ErrorAction SilentlyContinue
    Write-Log "Finalny stan BitLocker: $($blFinal.VolumeStatus) / % przetworzenia: $($blFinal.EncryptionPercentage)%" INFO
}
catch {
    # Cicho, jeśli BitLocker niedostępny
}

# Podsumowanie
Write-Log '==========================================' INFO
Write-Log '  Skrypt wdrożeniowy zakończony.'           INFO
Write-Log "  Log: $LogPath"                            INFO
if ($wingetFailed.Count -gt 0) {
    Write-Log "  Aplikacje winget z błędem: $($wingetFailed.Count)" WARN
}
Write-Log '  WYMAGANY RESTART (dołączenie do domeny).' WARN
Write-Log '==========================================' INFO

Stop-Transcript

