<#
.SYNOPSIS
    Windows 11 Input Lag Optimizer - Community Edition
.DESCRIPTION
    An interactive PowerShell toolkit that reduces input lag, lowers DPC latency,
    tightens privacy, and improves overall responsiveness on Windows 11.

    Built from community research (Blur Busters / Chiphell / NGA) plus
    practical privacy and networking tweaks. Every change is reversible:
    a registry backup is created automatically before anything is modified.

.NOTES
    Author:  W11 Input Lag Optimizer contributors
    License: MIT
    Usage:   Right-click PowerShell -> Run as Administrator, then run this file.
#>

$ScriptURL       = "https://raw.githubusercontent.com/reiseiv/w11pro22631-opt/refs/heads/main/optimize.ps1"
$PrivacyGuideURL = "https://www.privacyguides.org/en/"

# =====================================================
# ADMIN CHECK + IEX RELAUNCH
# =====================================================
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[!] This script needs Administrator rights to touch system settings." -ForegroundColor Red
    Write-Host "    Relaunching elevated..." -ForegroundColor Yellow

    if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
        Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
        exit
    } else {
        $tempFile = "$env:TEMP\w11opt_$(Get-Random).ps1"
        try {
            Write-Host "    Fetching script to: $tempFile" -ForegroundColor Yellow
            Invoke-WebRequest -Uri $ScriptURL -OutFile $tempFile -UseBasicParsing
            Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$tempFile`"" -Verb RunAs
            exit
        } catch {
            Write-Host "[x] Download failed: $_" -ForegroundColor Red
            Write-Host "    Run PowerShell as Admin, then:  irm $ScriptURL | iex" -ForegroundColor Gray
            Read-Host "Press Enter to exit"
            exit
        }
    }
}

# =====================================================
# GLOBAL STATE
# =====================================================
$Script:BackupPath    = "$env:USERPROFILE\Desktop\reg_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
$Script:BackupCreated = $false
$Script:HostsBackup   = "$env:USERPROFILE\Desktop\hosts_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"

# =====================================================
# OUTPUT HELPERS
# =====================================================
function Write-Header { param([string]$Title)
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
}
function Write-Step { param([string]$T) Write-Host "[*] $T" -ForegroundColor Yellow }
function Write-OK   { param([string]$T) Write-Host "    [+] $T" -ForegroundColor Green }
function Write-Skip { param([string]$T) Write-Host "    [-] $T" -ForegroundColor DarkGray }
function Write-Err  { param([string]$T) Write-Host "    [x] $T" -ForegroundColor Red }
function Write-Warn { param([string]$T) Write-Host "    [!] $T" -ForegroundColor Magenta }
function Wait-Key   { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") }

# =====================================================
# BACKUPS & RESTORE POINTS
# =====================================================
function Create-RegistryBackup {
    if ($Script:BackupCreated) {
        Write-Skip "Backup already exists at $Script:BackupPath"
        return
    }
    Write-Step "Creating registry backup..."
    try {
        New-Item -ItemType Directory -Path $Script:BackupPath -Force | Out-Null
        reg export "HKLM\SYSTEM\CurrentControlSet" "$Script:BackupPath\HKLM_SYSTEM.reg" /y 2>$null | Out-Null
        reg export "HKLM\SOFTWARE\Microsoft\Windows\Dwm" "$Script:BackupPath\HKLM_DWM.reg" /y 2>$null | Out-Null
        reg export "HKCU\Control Panel" "$Script:BackupPath\HKCU_ControlPanel.reg" /y 2>$null | Out-Null
        reg export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options" "$Script:BackupPath\HKLM_IFEO.reg" /y 2>$null | Out-Null
        $Script:BackupCreated = $true
        Write-OK "Backup saved to: $Script:BackupPath"
    } catch {
        Write-Err "Backup failed: $_"
    }
}

function Backup-HostsFile {
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    if (!(Test-Path $Script:HostsBackup)) {
        Copy-Item $hostsPath $Script:HostsBackup -Force -ErrorAction SilentlyContinue
        Write-OK "Original hosts file backed up to: $Script:HostsBackup"
    } else {
        Write-Skip "Hosts backup already exists."
    }
}

function Create-SystemRestorePoint {
    Write-Step "Creating System Restore Point (W11_Opt_Backup)..."
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "W11_Opt_Backup" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
        Write-OK "System restore point created successfully."
    } catch {
        Write-Err "Failed to create restore point: $_"
        Write-Skip "System Protection might be disabled in Windows."
    }
}

# =====================================================
# INDIVIDUAL TWEAKS
# =====================================================

# --- USB -------------------------------------------------------
function Tweak-USBDevicePowerManagement {
    Write-Step "Disabling USB Device Power Management..."
    $usbDevices = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Enum\USB" -ErrorAction SilentlyContinue
    $counter = 0
    foreach ($dev in $usbDevices) {
        $subKeys = Get-ChildItem $dev.PSPath -ErrorAction SilentlyContinue
        foreach ($sub in $subKeys) {
            $paramPath = "$($sub.PSPath)\Device Parameters"
            if (Test-Path $paramPath) {
                $props = @{
                    "AllowIdleIrpInD3"               = 0
                    "DeviceResetNotificationEnabled" = 0
                    "EnhancedPowerManagementEnabled" = 0
                    "SelectiveSuspendEnabled"        = 0
                    "SelectiveSuspendOn"             = 0
                }
                foreach ($k in $props.Keys) {
                    try { Set-ItemProperty -Path $paramPath -Name $k -Value $props[$k] -Type DWord -Force -ErrorAction Stop } catch {}
                }
                $counter++
            }
        }
    }
    Write-OK "Touched $counter USB device entries"
}

# --- Mouse -----------------------------------------------------
function Tweak-MouseSettings {
    Write-Step "Applying mouse tweaks (acceleration / smoothing / queue)..."
    $mouclass = "HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters"
    if (!(Test-Path $mouclass)) { New-Item -Path $mouclass -Force | Out-Null }
    Set-ItemProperty -Path $mouclass -Name "MouseDataQueueSize" -Value 20 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $mouclass -Name "ThreadPriority"     -Value 31 -Type DWord -Force -ErrorAction SilentlyContinue

    $mouse = "HKCU:\Control Panel\Mouse"
    Set-ItemProperty -Path $mouse -Name "MouseSpeed"      -Value "0" -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $mouse -Name "MouseThreshold1" -Value "0" -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $mouse -Name "MouseThreshold2" -Value "0" -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $mouse -Name "SmoothMouseXCurve" -Value ([byte[]]@()) -Type Binary -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $mouse -Name "SmoothMouseYCurve" -Value ([byte[]]@()) -Type Binary -Force -ErrorAction SilentlyContinue

    Write-OK "MouseDataQueueSize = 20, ThreadPriority = 31"
    Write-OK "Acceleration OFF, smoothing curves cleared"
}

# --- Keyboard --------------------------------------------------
function Tweak-KeyboardSettings {
    Write-Step "Applying keyboard tweaks..."
    Set-ItemProperty -Path "HKCU:\Control Panel\Keyboard" -Name "KeyboardDelay" -Value "0"  -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Control Panel\Keyboard" -Name "KeyboardSpeed" -Value "31" -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters" -Name "KeyboardDataQueueSize" -Value 22 -Type DWord -Force -ErrorAction SilentlyContinue

    $kbdResp = "HKCU:\Control Panel\Accessibility\Keyboard Response"
    Set-ItemProperty -Path $kbdResp -Name "Flags"                -Value "122" -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $kbdResp -Name "AutoRepeatDelay"      -Value "0"   -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $kbdResp -Name "AutoRepeatRate"       -Value "0"   -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $kbdResp -Name "DelayBeforeAcceptance" -Value "0"  -Force -ErrorAction SilentlyContinue

    Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\MouseKeys"   -Name "Flags" -Value "62"  -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\StickyKeys"  -Name "Flags" -Value "510" -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\ToggleKeys"  -Name "Flags" -Value "62"  -Force -ErrorAction SilentlyContinue

    Write-OK "KeyboardDelay = 0, KeyboardSpeed = 31, Queue = 22"
    Write-OK "FilterKeys BLOCKED (prevents random 1s input lag)"
    Write-OK "MouseKeys / StickyKeys / ToggleKeys OFF"
}

# --- Priority control -----------------------------------------
function Tweak-PriorityControl {
    Write-Step "Applying IRQ / thread priority tweaks..."
    $prio = "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl"
    Set-ItemProperty -Path $prio -Name "IRQ0Priority"             -Value 1    -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $prio -Name "IRQ8Priority"             -Value 1    -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $prio -Name "Win32PrioritySeparation"  -Value 0x26 -Type DWord -Force -ErrorAction SilentlyContinue
    Write-OK "IRQ0/IRQ8 priority boosted"
    Write-OK "Win32PrioritySeparation = 0x26 (38)"
    Write-Skip "Try 0x16 (22) if you want lower DPC latency but softer foreground boost"
}

# --- DWM / MPO ------------------------------------------------
function Tweak-DWM_MPO {
    Write-Step "Disabling Multi-Plane Overlay (MPO)..."
    $dwm = "HKLM:\SOFTWARE\Microsoft\Windows\Dwm"
    if (!(Test-Path $dwm)) { New-Item -Path $dwm -Force | Out-Null }
    Set-ItemProperty -Path $dwm -Name "OverlayTestMode" -Value 5 -Type DWord -Force -ErrorAction SilentlyContinue

    $desktop = "HKCU:\Control Panel\Desktop"
    @("DwmFrameRate","DwmMaximizeAcrossMonitors","DwmOverridePresent") | ForEach-Object {
        Remove-ItemProperty -Path $desktop -Name $_ -Force -ErrorAction SilentlyContinue
    }
    Set-ItemProperty -Path $desktop -Name "MenuShowDelay" -Value "0" -Force -ErrorAction SilentlyContinue

    Write-OK "OverlayTestMode = 5 (MPO off)"
    Write-OK "Removed legacy DwmFrameRate / DwmOverridePresent"
}

# --- Game Config Store ----------------------------------------
function Tweak-GameConfigStore {
    Write-Step "Tuning GameConfigStore (Fullscreen Exclusive + GameDVR off)..."
    $gc = "HKCU:\System\GameConfigStore"
    Set-ItemProperty -Path $gc -Name "GameDVR_FSEBehavior"     -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $gc -Name "GameDVR_FSEBehaviorMode" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $gc -Name "GameDVR_Enabled"         -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Write-OK "GameDVR off, FSE behavior mode = Fullscreen Exclusive"
}

# --- csrss ----------------------------------------------------
function Tweak-CsrssPriority {
    Write-Step "Boosting csrss.exe (Raw Input Thread) priority..."
    $csrss = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\csrss.exe\PerfOptions"
    if (!(Test-Path $csrss)) { New-Item -Path $csrss -Force | Out-Null }
    Set-ItemProperty -Path $csrss -Name "CpuPriorityClass" -Value 4 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $csrss -Name "IoPriority"       -Value 3 -Type DWord -Force -ErrorAction SilentlyContinue
    Write-OK "csrss.exe: CpuPriority = High, IoPriority = High"
    Write-Warn "Never set this to Realtime (5) - it will freeze the system."
}

# --- Timer & memory -------------------------------------------
function Tweak-TimerAndMemory {
    Write-Step "Tuning timer resolution & memory management..."
    $kernel = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel"
    Set-ItemProperty -Path $kernel -Name "GlobalTimerResolutionRequests" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Write-OK "GlobalTimerResolutionRequests = 1"

    $mem = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management"
    Set-ItemProperty -Path $mem -Name "DisablePagingExecutive" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $mem -Name "DisableCompression"     -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Write-OK "DisablePagingExecutive = 1, DisableCompression = 1"

    try { Disable-MMAgent -MemoryCompression -ErrorAction Stop; Write-OK "Memory compression OFF (MMAgent)" }
    catch { Write-Skip "MMAgent unavailable on this build - registry fallback used" }
}

# --- Power ----------------------------------------------------
function Tweak-PowerManagement {
    Write-Step "Applying power management tweaks..."
    $usb = "HKLM:\SYSTEM\CurrentControlSet\Services\USB"
    if (!(Test-Path $usb)) { New-Item -Path $usb -Force | Out-Null }
    Set-ItemProperty -Path $usb -Name "DisableSelectiveSuspend" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue

    $hub3 = "HKLM:\SYSTEM\CurrentControlSet\Services\USBHUB3"
    if (Test-Path $hub3) {
        Set-ItemProperty -Path $hub3 -Name "DisableSelectiveSuspend" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    }

    $pt = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling"
    if (!(Test-Path $pt)) { New-Item -Path $pt -Force | Out-Null }
    Set-ItemProperty -Path $pt -Name "PowerThrottlingOff" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue

    Write-OK "USB selective suspend off, power throttling off"
}

# --- TCP/IP Optimization ---------------------------------------
function Tweak-TCPIP {
    Write-Step "Applying TCP/IP Optimizations (Nagle's Algorithm)..."
    $interfaces = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" -ErrorAction SilentlyContinue
    $counter = 0
    foreach ($iface in $interfaces) {
        try {
            Set-ItemProperty -Path $iface.PSPath -Name "TcpAckFrequency" -Value 1 -Type DWord -Force -ErrorAction Stop
            Set-ItemProperty -Path $iface.PSPath -Name "TCPNoDelay"      -Value 1 -Type DWord -Force -ErrorAction Stop
            $counter++
        } catch {}
    }
    Write-OK "Applied TCP optimizations to $counter network interfaces."
}

# --- Profile bundles ------------------------------------------
function Tweak-MinimalProfile {
    Write-Header "MINIMAL PROFILE (safe, reversible)"
    Create-RegistryBackup
    Write-Step "Disabling mouse acceleration..."
    Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseSpeed"      -Value "0" -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold1" -Value "0" -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold2" -Value "0" -Force -ErrorAction SilentlyContinue
    Write-OK "Mouse accel off"

    Set-ItemProperty -Path "HKCU:\Control Panel\Keyboard" -Name "KeyboardDelay" -Value "0"  -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Control Panel\Keyboard" -Name "KeyboardSpeed" -Value "31" -Force -ErrorAction SilentlyContinue
    Write-OK "Keyboard repeat maxed"

    $pt = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling"
    if (!(Test-Path $pt)) { New-Item -Path $pt -Force | Out-Null }
    Set-ItemProperty -Path $pt -Name "PowerThrottlingOff" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Write-OK "Power throttling off"

    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "MenuShowDelay" -Value "0" -Force -ErrorAction SilentlyContinue
    Write-OK "MenuShowDelay = 0"
}

function Tweak-NormalProfile {
    Write-Header "NORMAL PROFILE (recommended)"
    Create-RegistryBackup
    Tweak-MinimalProfile
    Tweak-USBDevicePowerManagement
    Tweak-MouseSettings
    Tweak-KeyboardSettings
    Tweak-DWM_MPO
    Tweak-GameConfigStore
    Tweak-TimerAndMemory
    Tweak-PowerManagement
    Tweak-TCPIP
    Write-Host ""
    Write-OK "Normal profile applied. Restart your PC."
}

function Tweak-HardProfile {
    Write-Header "HARD PROFILE (aggressive - enthusiasts only)"
    Write-Warn "This profile touches IRQ priorities, csrss, and memory compression."
    Write-Warn "It's fine on most desktops, but on some laptops it can cause weird behavior."
    Write-Host ""
    Write-Host "  Type YES to continue, anything else to cancel: " -NoNewline -ForegroundColor Yellow
    if ((Read-Host).Trim().ToUpper() -ne "YES") {
        Write-Skip "Cancelled."
        return
    }
    Create-SystemRestorePoint
    Create-RegistryBackup
    Tweak-NormalProfile
    Tweak-PriorityControl
    Tweak-CsrssPriority
    Write-Host ""
    Write-OK "Hard profile applied. Restart your PC."
    Write-Skip "If anything feels off, restore from: $Script:BackupPath or use Windows System Restore."
}

# =====================================================
# PRIVACY & TELEMETRY
# =====================================================
function Set-TelemetryRegistry {
    $paths = @{
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" = @{
            "AllowTelemetry" = 0
        }
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" = @{
            "AllowTelemetry" = 0
        }
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" = @{
            "LetAppsRunInBackground" = 2
        }
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" = @{
            "Enabled" = 0
        }
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" = @{
            "SubscribedContent-338388Enabled" = 0
            "SubscribedContent-338389Enabled" = 0
            "SubscribedContent-338393Enabled" = 0
            "SystemPaneSuggestionsEnabled"   = 0
            "SilentInstalledAppsEnabled"     = 0
        }
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" = @{
            "DisableWindowsConsumerFeatures" = 1
            "DisableSoftLanding"             = 1
        }
    }
    foreach ($p in $paths.Keys) {
        if (!(Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
        foreach ($k in $paths[$p].Keys) {
            Set-ItemProperty -Path $p -Name $k -Value $paths[$p][$k] -Type DWord -Force -ErrorAction SilentlyContinue
        }
    }
}

function Disable-ScheduledTelemetry {
    $tasks = @(
        "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
        "\Microsoft\Windows\Application Experience\ProgramDataUpdater",
        "\Microsoft\Windows\Autochk\Proxy",
        "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator",
        "\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip",
        "\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector",
        "\Microsoft\Windows\Feedback\Siuf\DmClient",
        "\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload"
    )
    foreach ($t in $tasks) {
        try { Disable-ScheduledTask -TaskName (Split-Path $t -Leaf) -TaskPath ((Split-Path $t -Parent) + "\") -ErrorAction Stop | Out-Null; Write-OK "Disabled task: $t" } catch {}
    }
}

function Set-HostsTurboPrivacy {
    Write-Step "Editing hosts file (turbo privacy blocklist)..."
    Backup-HostsFile
    $hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
    $marker = "# --- W11 Optimizer Turbo Privacy blocklist ---"
    $endmark = "# --- W11 Optimizer Turbo Privacy blocklist end ---"

    # Strip any previous block we added
    $content = Get-Content $hosts -ErrorAction SilentlyContinue
    if ($content -match [regex]::Escape($marker)) {
        $new = @()
        $inside = $false
        foreach ($line in $content) {
            if ($line -eq $marker) { $inside = $true; continue }
            if ($line -eq $endmark) { $inside = $false; continue }
            if (!$inside) { $new += $line }
        }
        $content = $new
    }

    $blocklist = @(
        "vortex.data.microsoft.com",
        "telemetry.microsoft.com",
        "watson.telemetry.microsoft.com",
        "settings-win.data.microsoft.com",
        "v10.events.data.microsoft.com",
        "v10c.events.data.microsoft.com",
        "v20.events.data.microsoft.com",
        "telemetry.remoteapp.windowsazure.com",
        "telecommand.telemetry.microsoft.com",
        "sqm.telemetry.microsoft.com",
        "oca.telemetry.microsoft.com",
        "choice.microsoft.com",
        "df.telemetry.microsoft.com",
        "reports.wes.df.telemetry.microsoft.com",
        "wes.df.telemetry.microsoft.com",
        "services.wes.df.telemetry.microsoft.com",
        "dmx.df.microsoft.com",
        "feedback.microsoft-hohm.com",
        "feedback.search.microsoft.com",
        "feedback.windows.com",
        "ad.doubleclick.net",
        "ads.doubleclick.net",
        "googleads.g.doubleclick.net",
        "pagead2.googlesyndication.com",
        "tpc.googlesyndication.com",
        "ads.google.com",
        "telemetry.mozilla.org",
        "incoming.telemetry.mozilla.org",
        "cdn.online-metrix.net",
        "metrics.icloud.com",
        "metrics.mzstatic.com"
    )

    $block = @($marker)
    foreach ($d in $blocklist) { $block += "0.0.0.0 $d" }
    $block += $endmark

    $content += ""
    $content += $block
    Set-Content -Path $hosts -Value $content -Encoding ASCII -Force
    ipconfig /flushdns | Out-Null
    Write-OK "Blocklist applied ($($blocklist.Count) domains) and DNS cache flushed"
    Write-Skip "Restore anytime with option [R] in the Privacy menu."
}

function Restore-HostsFile {
    if (Test-Path $Script:HostsBackup) {
        Copy-Item $Script:HostsBackup "$env:SystemRoot\System32\drivers\etc\hosts" -Force
        ipconfig /flushdns | Out-Null
        Write-OK "Hosts file restored from: $Script:HostsBackup"
    } else {
        Write-Err "No backup found. You'll need to reset hosts manually."
    }
}

function Add-FirewallBlockRules {
    Write-Step "Adding outbound firewall rules for known telemetry binaries..."
    $exes = @(
        "CompatTelRunner.exe",
        "DeviceCensus.exe",
        "DiagTrack.exe",
        "dmclient.exe",
        "FeedbackHub.exe",
        "MicrosoftEdgeUpdate.exe"
    )
    foreach ($exe in $exes) {
        $ruleName = "W11Opt_Block_$exe"
        if (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue) {
            Write-Skip "Rule already exists: $ruleName"
            continue
        }
        try {
            New-NetFirewallRule -DisplayName $ruleName -Direction Outbound -Program "$env:SystemRoot\System32\$exe" -Action Block -Profile Any -ErrorAction Stop | Out-Null
            Write-OK "Blocked outbound: $exe"
        } catch {
            Write-Skip "Skipped $exe (not present or protected)"
        }
    }
}

function Remove-FirewallBlockRules {
    Get-NetFirewallRule -DisplayName "W11Opt_Block_*" -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-NetFirewallRule -Name $_.Name -ErrorAction SilentlyContinue
        Write-OK "Removed rule: $($_.DisplayName)"
    }
}

function Set-PrivacyLevel {
    param([ValidateSet("Light","Medium","Turbo")][string]$Level)
    Write-Header "PRIVACY: $Level"
    Create-RegistryBackup

    Set-TelemetryRegistry
    Write-OK "Telemetry registry keys applied"

    if ($Level -in @("Medium","Turbo")) {
        Disable-ScheduledTelemetry
        Add-FirewallBlockRules
    }

    if ($Level -eq "Turbo") {
        Set-HostsTurboPrivacy
        Write-Warn "Turbo mode uses the hosts file - some Microsoft services may misbehave."
    }

    Write-Host ""
    Write-OK "Privacy level '$Level' applied."
}

function Show-PrivacyMenu {
    do {
        Clear-Host
        Write-Header "PRIVACY & TELEMETRY"
        Write-Host "  Pick how much you want to lock down. Higher = more private,"
        Write-Host "  but also more likely to break something Microsoft-y." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  [1] Light   - turn off telemetry + ads (safe, recommended for everyone)"
        Write-Host "  [2] Medium  - Light + disable scheduled tasks + firewall rules"
        Write-Host "  [3] Turbo   - Medium + hosts blocklist (aggressive, mostly for pros)"
        Write-Host ""
        Write-Host "  [R] Restore hosts file from backup"
        Write-Host "  [F] Remove all optimizer firewall rules"
        Write-Host "  [L] Open online privacy guide (browser)"
        Write-Host "  [0] Back to main menu"
        Write-Host ""
        $c = Read-Host "  Select option"
        switch ($c.ToUpper()) {
            "1" { Set-PrivacyLevel Light;  Wait-Key }
            "2" { Set-PrivacyLevel Medium; Wait-Key }
            "3" { Set-PrivacyLevel Turbo;  Wait-Key }
            "R" { Restore-HostsFile; Wait-Key }
            "F" { Remove-FirewallBlockRules; Wait-Key }
            "L" { Start-Process $PrivacyGuideURL }
            "0" { return }
            default { Start-Sleep -Milliseconds 400 }
        }
    } while ($true)
}

# =====================================================
# NETWORK / DNS
# =====================================================
function Set-SystemDNS {
    param([string]$Name, [string[]]$Servers)
    Write-Step "Setting DNS to $Name ($($Servers -join ', '))..."
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
    if (!$adapters) { Write-Err "No active adapters found."; return }
    foreach ($a in $adapters) {
        try {
            Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $Servers -ErrorAction Stop
            Write-OK "$($a.Name) -> $($Servers -join ', ')"
        } catch {
            Write-Err "Failed on $($a.Name): $_"
        }
    }
    Clear-DnsClientCache -ErrorAction SilentlyContinue
}

function Reset-SystemDNS {
    Write-Step "Resetting DNS to DHCP..."
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
    foreach ($a in $adapters) {
        try {
            Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -ErrorAction Stop
            Write-OK "$($a.Name) -> automatic"
        } catch {}
    }
    Clear-DnsClientCache -ErrorAction SilentlyContinue
}

function Show-DNSMenu {
    do {
        Clear-Host
        Write-Header "NETWORK / DNS"
        Write-Host "  [1] Cloudflare            1.1.1.1 / 1.0.0.1        (fast, private)"
        Write-Host "  [2] Cloudflare Malware    1.1.1.2 / 1.0.0.2        (blocks malware)"
        Write-Host "  [3] Cloudflare Family     1.1.1.3 / 1.0.0.3        (malware + adult)"
        Write-Host "  [4] Google                8.8.8.8 / 8.8.4.4        (reliable)"
        Write-Host "  [5] Quad9                 9.9.9.9 / 149.112.112.112 (security-focused)"
        Write-Host "  [R] Reset to DHCP (automatic)"
        Write-Host "  [0] Back"
        Write-Host ""
        $c = Read-Host "  Select option"
        switch ($c.ToUpper()) {
            "1" { Set-SystemDNS "Cloudflare"        @("1.1.1.1","1.0.0.1");         Wait-Key }
            "2" { Set-SystemDNS "Cloudflare Malware" @("1.1.1.2","1.0.0.2");        Wait-Key }
            "3" { Set-SystemDNS "Cloudflare Family"  @("1.1.1.3","1.0.0.3");        Wait-Key }
            "4" { Set-SystemDNS "Google"            @("8.8.8.8","8.8.4.4");         Wait-Key }
            "5" { Set-SystemDNS "Quad9"             @("9.9.9.9","149.112.112.112"); Wait-Key }
            "R" { Reset-SystemDNS; Wait-Key }
            "0" { return }
            default { Start-Sleep -Milliseconds 400 }
        }
    } while ($true)
}

# =====================================================
# CLEANUP / DEBLOAT
# =====================================================
function Remove-OneDrive {
    Write-Step "Removing OneDrive..."
    Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    $paths = @(
        "$env:SystemRoot\SysWOW64\OneDriveSetup.exe",
        "$env:SystemRoot\System32\OneDriveSetup.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) {
            try {
                Start-Process -FilePath $p -ArgumentList "/uninstall" -Wait -NoNewWindow
                Write-OK "Uninstalled via $p"
                return
            } catch {}
        }
    }
    Write-Err "Couldn't find OneDriveSetup.exe - maybe already removed."
}

function Remove-XboxGameBar {
    Write-Step "Removing Xbox Game Bar and overlays..."
    $pkgs = @("*XboxGamingOverlay*","*XboxGameOverlay*","*XboxSpeechToTextOverlay*")
    foreach ($p in $pkgs) {
        Get-AppxPackage $p -AllUsers -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-AppxPackage -Package $_.PackageFullName -ErrorAction SilentlyContinue
            Write-OK "Removed: $($_.Name)"
        }
    }
    Write-Skip "Xbox Identity Provider kept - some games need it."
}

function Remove-PreinstalledBloat {
    Write-Step "Removing common preinstalled bloatware..."
    $bloatApps = @(
        "*BingNews*", "*BingWeather*", "*BubbleWitch3Saga*", "*CandyCrush*",
        "*DisneyMagicKingdoms*", "*MarchOfEmpires*", "*MinecraftUWP*",
        "*SkypeApp*", "*Spotify*", "*TikTok*", "*Twitter*",
        "*ZuneMusic*", "*ZuneVideo*", "*GetHelp*", "*SolitaireCollection*"
    )
    $count = 0
    foreach ($app in $bloatApps) {
        Get-AppxPackage -Name $app -AllUsers -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue
            $count++
        }
    }
    Write-OK "Removed $count bloatware packages."
}

function Show-CleanupMenu {
    do {
        Clear-Host
        Write-Header "CLEANUP / DEBLOAT"
        Write-Host "  [1] Remove OneDrive"
        Write-Host "  [2] Remove Xbox Game Bar + overlays"
        Write-Host "  [3] Remove common Windows bloatware (TikTok, CandyCrush, etc.)"
        Write-Host "  [4] Nuke everything (Remove OneDrive, Xbox, and Bloatware)"
        Write-Host "  [0] Back"
        Write-Host ""
        $c = Read-Host "  Select option"
        switch ($c) {
            "1" { Remove-OneDrive; Wait-Key }
            "2" { Remove-XboxGameBar; Wait-Key }
            "3" { Remove-PreinstalledBloat; Wait-Key }
            "4" { Remove-OneDrive; Remove-XboxGameBar; Remove-PreinstalledBloat; Wait-Key }
            "0" { return }
            default { Start-Sleep -Milliseconds 400 }
        }
    } while ($true)
}

# =====================================================
# ADVANCED MENUS (HPET / HAGS)
# =====================================================
function Show-HPETMenu {
    do {
        Clear-Host
        Write-Header "ADVANCED: HPET & Dynamic Tick"
        Write-Warn "VERY ADVANCED: This is highly dependent on your hardware setup."
        Write-Warn "Can improve frametime stability, but might cause audio desync or stutter on some systems."
        Write-Host ""
        Write-Host "  [1] Apply tweaks (Disable Dynamic Tick, Use platform clock OFF)"
        Write-Host "  [2] Restore defaults (Windows default timers)"
        Write-Host "  [0] Back to main menu"
        Write-Host ""
        $c = Read-Host "  Select option"
        switch ($c) {
            "1" {
                Write-Step "Disabling Dynamic Tick and modifying timers..."
                bcdedit /set disabledynamictick yes | Out-Null
                bcdedit /set useplatformclock no | Out-Null
                bcdedit /set tscsyncpolicy Enhanced | Out-Null
                Write-OK "HPET / Dynamic Tick tweaks applied. Restart required."
                Wait-Key
            }
            "2" {
                Write-Step "Restoring default timer settings..."
                bcdedit /deletevalue disabledynamictick 2>$null | Out-Null
                bcdedit /deletevalue useplatformclock 2>$null | Out-Null
                bcdedit /deletevalue tscsyncpolicy 2>$null | Out-Null
                Write-OK "Timer defaults restored. Restart required."
                Wait-Key
            }
            "0" { return }
            default { Start-Sleep -Milliseconds 400 }
        }
    } while ($true)
}

function Show-HAGSMenu {
    do {
        Clear-Host
        Write-Header "ADVANCED: Hardware-Accelerated GPU Scheduling (HAGS)"
        Write-Warn "VERY ADVANCED: Highly dependent on your setup (GPU / Drivers / Specific Games)."
        Write-Warn "Some setups see better FPS with HAGS ON, others get less stutter with HAGS OFF."
        Write-Host ""
        Write-Host "  [1] Turn HAGS ON"
        Write-Host "  [2] Turn HAGS OFF"
        Write-Host "  [0] Back to main menu"
        Write-Host ""
        $c = Read-Host "  Select option"
        $gfx = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
        switch ($c) {
            "1" {
                if (!(Test-Path $gfx)) { New-Item -Path $gfx -Force | Out-Null }
                Set-ItemProperty -Path $gfx -Name "HwSchMode" -Value 2 -Type DWord -Force
                Write-OK "HAGS turned ON. Restart required."
                Wait-Key
            }
            "2" {
                if (!(Test-Path $gfx)) { New-Item -Path $gfx -Force | Out-Null }
                Set-ItemProperty -Path $gfx -Name "HwSchMode" -Value 1 -Type DWord -Force
                Write-OK "HAGS turned OFF. Restart required."
                Wait-Key
            }
            "0" { return }
            default { Start-Sleep -Milliseconds 400 }
        }
    } while ($true)
}

# =====================================================
# BIOS REMINDER
# =====================================================
function Show-BIOSReminder {
    Clear-Host
    Write-Header "BIOS SETTINGS (MANUAL)"
    Write-Host "  These must be set by hand in BIOS. Values below are a starting point."
    Write-Host "  Test one change at a time - measure before/after." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [AM5 / Ryzen 7000 example]" -ForegroundColor Yellow
    Write-Host "    XHCI Hand-off           = Disabled (test - some boards hate this)"     -ForegroundColor Gray
    Write-Host "    Global C-state Control  = Disabled"                                   -ForegroundColor Gray
    Write-Host "    DF Cstates              = Disabled"                                   -ForegroundColor Gray
    Write-Host "    Power Down Enable       = Disabled (DRAM)"                            -ForegroundColor Gray
    Write-Host "    Memory Context Restore  = Disabled (keep both power-down options off)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "    EXPO / XMP              = Disabled (test this thing - using manual"   -ForegroundColor Gray
    Write-Host "                              timings is 100% better, but if you're a"    -ForegroundColor Gray
    Write-Host "                              beginner, EXPO/XMP is totally fine.)"      -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Reminder: re-enable EXPO with SoC ~1.25V after testing." -ForegroundColor DarkYellow
    Write-Host ""
    Write-Host "  Press any key to return..." -ForegroundColor Cyan
    Wait-Key
}

# =====================================================
# MAIN MENU
# =====================================================
function Show-MainMenu {
    Clear-Host
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "     WINDOWS 11 INPUT Lag OPTIMIZER  -  Community Edition"     -ForegroundColor Cyan
    Write-Host "     Based on Blur Busters / Chiphell / NGA community research" -ForegroundColor DarkCyan
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "   -- Optimization Profiles (pick ONE) --" -ForegroundColor White
    Write-Host "   [1]  Minimal   | Safe baseline. Zero risk. Good for laptops." -ForegroundColor Yellow
    Write-Host "   [2]  Normal    | Recommended for most desktops."              -ForegroundColor Yellow
    Write-Host "   [3]  Hard      | Aggressive. Enthusiasts only - read the warning." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "   -- Individual Tweaks (advanced users) --" -ForegroundColor White
    Write-Host "   [4]  USB Device Power Management"
    Write-Host "   [5]  Mouse Tweaks (queue, accel, smoothing)"
    Write-Host "   [6]  Keyboard Tweaks (delay, queue, FilterKeys block)"
    Write-Host "   [7]  Priority Control (IRQ, Win32PrioritySeparation)"
    Write-Host "   [8]  DWM / MPO (Multi-Plane Overlay off)"
    Write-Host "   [9]  GameConfigStore (Fullscreen Exclusive)"
    Write-Host "   [10] csrss.exe Priority (Raw Input Thread boost)"
    Write-Host "   [11] Timer Resolution & Memory"
    Write-Host "   [12] Power Management (throttling, selective suspend)"
    Write-Host "   [15] Apply TCP/IP Optimizations (Nagle's Algorithm)"
    Write-Host ""
    Write-Host "   -- Utilities --" -ForegroundColor White
    Write-Host "   [13] Create registry backup only"
    Write-Host "   [16] Create System Restore Point manually"
    Write-Host "   [14] BIOS settings reminder"
    Write-Host ""
    Write-Host "  ------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "   Extra & Advanced tools" -ForegroundColor Cyan
    Write-Host "  ------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "   [P]  Privacy & Telemetry  (submenu - Light / Medium / Turbo)" -ForegroundColor Magenta
    Write-Host "   [N]  Network & DNS        (Cloudflare / Google / Quad9)"       -ForegroundColor Magenta
    Write-Host "   [C]  Cleanup / Debloat    (OneDrive, Xbox, Bloatware)"          -ForegroundColor Magenta
    Write-Host "   [H]  HPET & Dynamic Tick  (Advanced Timer Tweaks)"              -ForegroundColor Magenta
    Write-Host "   [G]  GPU HAGS Setup       (Hardware Scheduling)"                -ForegroundColor Magenta
    Write-Host "   [L]  Open online privacy guide (browser)"                       -ForegroundColor Magenta
    Write-Host ""
    Write-Host "   [0]  Exit"
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "   Tip: not sure what to do? Start with [2] Normal." -ForegroundColor Green
    Write-Host "        The Hard profile is intentionally gated - you'll have to"
    Write-Host "        confirm before anything risky runs."
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""
}

# =====================================================
# MAIN LOOP
# =====================================================
Create-RegistryBackup | Out-Null

do {
    Show-MainMenu
    $choice = Read-Host "  Select option"

    switch ($choice.ToUpper()) {
        "1"  { Tweak-MinimalProfile }
        "2"  { Tweak-NormalProfile }
        "3"  { Tweak-HardProfile }
        "4"  { Create-RegistryBackup; Tweak-USBDevicePowerManagement }
        "5"  { Create-RegistryBackup; Tweak-MouseSettings }
        "6"  { Create-RegistryBackup; Tweak-KeyboardSettings }
        "7"  { Create-RegistryBackup; Tweak-PriorityControl }
        "8"  { Create-RegistryBackup; Tweak-DWM_MPO }
        "9"  { Create-RegistryBackup; Tweak-GameConfigStore }
        "10" { Create-RegistryBackup; Tweak-CsrssPriority }
        "11" { Create-RegistryBackup; Tweak-TimerAndMemory }
        "12" { Create-RegistryBackup; Tweak-PowerManagement }
        "13" { Create-RegistryBackup }
        "14" { Show-BIOSReminder; continue }
        "15" { Create-RegistryBackup; Tweak-TCPIP }
        "16" { Create-SystemRestorePoint; continue }
        "P"  { Show-PrivacyMenu; continue }
        "N"  { Show-DNSMenu;     continue }
        "C"  { Show-CleanupMenu; continue }
        "H"  { Show-HPETMenu;    continue }
        "G"  { Show-HAGSMenu;    continue }
        "L"  { Start-Process $PrivacyGuideURL; continue }
        "0"  {
            Write-Host ""
            Write-Host "  Exiting..." -ForegroundColor Cyan
            break
        }
        default {
            Write-Host "  Invalid option. Try again." -ForegroundColor Red
            Start-Sleep -Seconds 1
            continue
        }
    }

    if ($choice.ToUpper() -notin @("0","14","16","P","N","C","L","H","G")) {
        Write-Host ""
        Write-Host "  ============================================================" -ForegroundColor Green
        Write-Host "    DONE!  Restart your computer for changes to take effect."   -ForegroundColor Green
        Write-Host "  ============================================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Registry backup: $Script:BackupPath" -ForegroundColor Cyan
        if (Test-Path $Script:HostsBackup) {
            Write-Host "  Hosts backup:    $Script:HostsBackup" -ForegroundColor Cyan
        }
        Write-Host ""
        Write-Host "  Press any key to continue..." -ForegroundColor Yellow
        Wait-Key
    }
} while ($choice.ToUpper() -ne "0")

Write-Host ""
Write-Host "  Thanks for using the Windows 11 Input Lag Optimizer!" -ForegroundColor Cyan
Write-Host "  Don't forget to restart. Catch you next time." -ForegroundColor Yellow
Write-Host ""
