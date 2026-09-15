
---

## 📄 `Optimize.ps1`

```powershell
<#
.SYNOPSIS
    Windows 11 Input Lag Optimizer
.DESCRIPTION
    Interactive PowerShell script for reducing input lag, DPC latency, and improving
    system responsiveness on Windows 11. Based on Blur Busters, Chiphell, and NGA research.
.NOTES
    Author: Windows 11 Input Lag Optimizer contributors
    License: MIT
    Tested on: Windows 11 23H2, Ryzen 7 7700, RTX 3060
#>

# =====================================================
# ADMIN CHECK
# =====================================================
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[!] This script requires Administrator privileges." -ForegroundColor Red
    Write-Host "    Relaunching with elevated privileges..." -ForegroundColor Yellow
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# =====================================================
# GLOBAL VARIABLES
# =====================================================
$Script:BackupPath = "$env:USERPROFILE\Desktop\reg_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
$Script:BackupCreated = $false

# =====================================================
# HELPER FUNCTIONS
# =====================================================
function Write-Header {
    param([string]$Title)
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step {
    param([string]$Text)
    Write-Host "[*] $Text" -ForegroundColor Yellow
}

function Write-OK {
    param([string]$Text)
    Write-Host "    [+] $Text" -ForegroundColor Green
}

function Write-Skip {
    param([string]$Text)
    Write-Host "    [-] $Text" -ForegroundColor DarkGray
}

function Write-Err {
    param([string]$Text)
    Write-Host "    [x] $Text" -ForegroundColor Red
}

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
        Write-Err "Failed to create backup: $_"
    }
}

# =====================================================
# TWEAK FUNCTIONS
# =====================================================

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
                    "AllowIdleIrpInD3"                = 0
                    "DeviceResetNotificationEnabled"  = 0
                    "EnhancedPowerManagementEnabled"  = 0
                    "SelectiveSuspendEnabled"         = 0
                    "SelectiveSuspendOn"              = 0
                }
                foreach ($key in $props.Keys) {
                    try {
                        Set-ItemProperty -Path $paramPath -Name $key -Value $props[$key] -Type DWord -Force -ErrorAction Stop
                    } catch {}
                }
                $counter++
            }
        }
    }
    
    Write-OK "Modified $counter USB device entries"
}

function Tweak-MouseSettings {
    Write-Step "Applying Mouse tweaks..."
    
    # MouseDataQueueSize + ThreadPriority
    $mouseClassPath = "HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters"
    if (!(Test-Path $mouseClassPath)) { New-Item -Path $mouseClassPath -Force | Out-Null }
    Set-ItemProperty -Path $mouseClassPath -Name "MouseDataQueueSize" -Value 20 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $mouseClassPath -Name "ThreadPriority" -Value 31 -Type DWord -Force -ErrorAction SilentlyContinue
    
    # Acceleration off
    $mousePath = "HKCU:\Control Panel\Mouse"
    Set-ItemProperty -Path $mousePath -Name "MouseSpeed" -Value "0" -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $mousePath -Name "MouseThreshold1" -Value "0" -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $mousePath -Name "MouseThreshold2" -Value "0" -Force -ErrorAction SilentlyContinue
    
    # SmoothMouse curves = zero-length
    Set-ItemProperty -Path $mousePath -Name "SmoothMouseXCurve" -Value ([byte[]]@()) -Type Binary -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $mousePath -Name "SmoothMouseYCurve" -Value ([byte[]]@()) -Type Binary -Force -ErrorAction SilentlyContinue
    
    Write-OK "MouseDataQueueSize = 20, ThreadPriority = 31"
    Write-OK "Acceleration OFF, SmoothMouse = zero-length"
}

function Tweak-KeyboardSettings {
    Write-Step "Applying Keyboard tweaks..."
    
    # Basic keyboard
    Set-ItemProperty -Path "HKCU:\Control Panel\Keyboard" -Name "KeyboardDelay" -Value "0" -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Control Panel\Keyboard" -Name "KeyboardSpeed" -Value "31" -Force -ErrorAction SilentlyContinue
    
    # KeyboardDataQueueSize
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters" -Name "KeyboardDataQueueSize" -Value 22 -Type DWord -Force -ErrorAction SilentlyContinue
    
    # --- CRITICAL: FilterKeys hotkey block ---
    $kbdRespPath = "HKCU:\Control Panel\Accessibility\Keyboard Response"
    Set-ItemProperty -Path $kbdRespPath -Name "Flags" -Value "122" -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $kbdRespPath -Name "AutoRepeatDelay" -Value "0" -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $kbdRespPath -Name "AutoRepeatRate" -Value "0" -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $kbdRespPath -Name "DelayBeforeAcceptance" -Value "0" -Force -ErrorAction SilentlyContinue
    
    # Other accessibility features OFF
    Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\MouseKeys" -Name "Flags" -Value "62" -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\StickyKeys" -Name "Flags" -Value "510" -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\ToggleKeys" -Name "Flags" -Value "62" -Force -ErrorAction SilentlyContinue
    
    Write-OK "KeyboardDelay = 0, KeyboardSpeed = 31, KeyboardDataQueueSize = 22"
    Write-OK "FilterKeys BLOCKED (Flags = 122) - prevents random 1s input lag"
    Write-OK "MouseKeys/StickyKeys/ToggleKeys OFF"
}

function Tweak-PriorityControl {
    Write-Step "Applying Priority Control tweaks..."
    
    $prioPath = "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl"
    Set-ItemProperty -Path $prioPath -Name "IRQ0Priority" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $prioPath -Name "IRQ8Priority" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $prioPath -Name "Win32PrioritySeparation" -Value 0x26 -Type DWord -Force -ErrorAction SilentlyContinue
    
    Write-OK "IRQ0Priority = 1, IRQ8Priority = 1"
    Write-OK "Win32PrioritySeparation = 0x26 (38)"
    Write-Skip "Alternative values to test: 0x16 (22) for lower DPC latency"
}

function Tweak-DWM_MPO {
    Write-Step "Disabling Multi-Plane Overlay (MPO)..."
    
    $dwmPath = "HKLM:\SOFTWARE\Microsoft\Windows\Dwm"
    if (!(Test-Path $dwmPath)) { New-Item -Path $dwmPath -Force | Out-Null }
    Set-ItemProperty -Path $dwmPath -Name "OverlayTestMode" -Value 5 -Type DWord -Force -ErrorAction SilentlyContinue
    
    # Remove harmful keys
    $desktopPath = "HKCU:\Control Panel\Desktop"
    @("DwmFrameRate", "DwmMaximizeAcrossMonitors", "DwmOverridePresent") | ForEach-Object {
        Remove-ItemProperty -Path $desktopPath -Name $_ -Force -ErrorAction SilentlyContinue
    }
    Set-ItemProperty -Path $desktopPath -Name "MenuShowDelay" -Value "0" -Force -ErrorAction SilentlyContinue
    
    Write-OK "OverlayTestMode = 5 (MPO OFF)"
    Write-OK "Removed DwmFrameRate, DwmOverridePresent (harmful)"
}

function Tweak-GameConfigStore {
    Write-Step "Applying GameConfigStore tweaks..."
    
    $gameStorePath = "HKCU:\System\GameConfigStore"
    Set-ItemProperty -Path $gameStorePath -Name "GameDVR_FSEBehavior" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $gameStorePath -Name "GameDVR_FSEBehaviorMode" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $gameStorePath -Name "GameDVR_Enabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    
    Write-OK "GameDVR_FSEBehavior = 0"
    Write-OK "GameDVR_FSEBehaviorMode = 2 (Fullscreen Exclusive)"
    Write-OK "GameDVR_Enabled = 0"
}

function Tweak-CsrssPriority {
    Write-Step "Setting csrss.exe priority (Raw Input Thread)..."
    
    $csrssPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\csrss.exe\PerfOptions"
    if (!(Test-Path $csrssPath)) { New-Item -Path $csrssPath -Force | Out-Null }
    Set-ItemProperty -Path $csrssPath -Name "CpuPriorityClass" -Value 4 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $csrssPath -Name "IoPriority" -Value 3 -Type DWord -Force -ErrorAction SilentlyContinue
    
    Write-OK "csrss.exe: CpuPriorityClass = 4 (High)"
    Write-OK "csrss.exe: IoPriority = 3 (High)"
    Write-Skip "WARNING: Do not use Realtime (5) - will freeze system"
}

function Tweak-TimerAndMemory {
    Write-Step "Applying Timer Resolution & Memory tweaks..."
    
    # Timer resolution
    $kernelPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel"
    Set-ItemProperty -Path $kernelPath -Name "GlobalTimerResolutionRequests" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Write-OK "GlobalTimerResolutionRequests = 1"
    
    # Memory
    $memPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management"
    Set-ItemProperty -Path $memPath -Name "DisablePagingExecutive" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $memPath -Name "DisableCompression" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Write-OK "DisablePagingExecutive = 1, DisableCompression = 1"
    
    # Try MMAgent (may not work on Canary)
    try {
        Disable-MMAgent -MemoryCompression -ErrorAction Stop
        Write-OK "Memory Compression OFF via MMAgent"
    } catch {
        Write-Skip "MMAgent not available (Canary), used registry instead"
    }
    
    Write-Skip "Use TimerResolution tool to set 0.5ms after restart"
}

function Tweak-PowerManagement {
    Write-Step "Applying Power Management tweaks..."
    
    # USB Selective Suspend
    $usbPath = "HKLM:\SYSTEM\CurrentControlSet\Services\USB"
    if (!(Test-Path $usbPath)) { New-Item -Path $usbPath -Force | Out-Null }
    Set-ItemProperty -Path $usbPath -Name "DisableSelectiveSuspend" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    
    $usbHub3 = "HKLM:\SYSTEM\CurrentControlSet\Services\USBHUB3"
    if (Test-Path $usbHub3) {
        Set-ItemProperty -Path $usbHub3 -Name "DisableSelectiveSuspend" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    }
    
    # Power Throttling
    $powerThrottlePath = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling"
    if (!(Test-Path $powerThrottlePath)) { New-Item -Path $powerThrottlePath -Force | Out-Null }
    Set-ItemProperty -Path $powerThrottlePath -Name "PowerThrottlingOff" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    
    Write-OK "USB Selective Suspend OFF"
    Write-OK "Power Throttling OFF"
}

function Apply-AllTweaks {
    Write-Header "APPLYING ALL TWEAKS"
    Create-RegistryBackup
    Tweak-USBDevicePowerManagement
    Tweak-MouseSettings
    Tweak-KeyboardSettings
    Tweak-PriorityControl
    Tweak-DWM_MPO
    Tweak-GameConfigStore
    Tweak-CsrssPriority
    Tweak-TimerAndMemory
    Tweak-PowerManagement
}

# =====================================================
# MENU
# =====================================================
function Show-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "    WINDOWS 11 INPUT LAG OPTIMIZER" -ForegroundColor Cyan
    Write-Host "    Based on Blur Busters / Chiphell / NGA research" -ForegroundColor DarkCyan
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1]  " -NoNewline -ForegroundColor Yellow; Write-Host "Apply ALL tweaks (recommended for fresh install)"
    Write-Host "  [2]  " -NoNewline -ForegroundColor Yellow; Write-Host "USB Device Power Management (disable power saving)"
    Write-Host "  [3]  " -NoNewline -ForegroundColor Yellow; Write-Host "Mouse Tweaks (queue, acceleration, smoothing)"
    Write-Host "  [4]  " -NoNewline -ForegroundColor Yellow; Write-Host "Keyboard Tweaks (delay, queue, FilterKeys BLOCK)"
    Write-Host "  [5]  " -NoNewline -ForegroundColor Yellow; Write-Host "Priority Control (IRQ, Win32PrioritySeparation)"
    Write-Host "  [6]  " -NoNewline -ForegroundColor Yellow; Write-Host "DWM / MPO Tweaks (Multi-Plane Overlay OFF)"
    Write-Host "  [7]  " -NoNewline -ForegroundColor Yellow; Write-Host "GameConfigStore (Fullscreen Exclusive)"
    Write-Host "  [8]  " -NoNewline -ForegroundColor Yellow; Write-Host "csrss.exe Priority (Raw Input Thread boost)"
    Write-Host "  [9]  " -NoNewline -ForegroundColor Yellow; Write-Host "Timer Resolution & Memory"
    Write-Host "  [10] " -NoNewline -ForegroundColor Yellow; Write-Host "Power Management (Throttling, Selective Suspend)"
    Write-Host "  [11] " -NoNewline -ForegroundColor Yellow; Write-Host "Create Registry Backup only"
    Write-Host "  [12] " -NoNewline -ForegroundColor Yellow; Write-Host "BIOS Settings reminder"
    Write-Host "  [0]  " -NoNewline -ForegroundColor Yellow; Write-Host "Exit"
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Show-BIOSReminder {
    Clear-Host
    Write-Header "BIOS SETTINGS (MANUAL)"
    Write-Host "  These settings MUST be set manually in BIOS:" -ForegroundColor White
    Write-Host ""
    Write-Host "  [AM5 / Ryzen 7000]" -ForegroundColor Yellow
    Write-Host "    XHCI Hand-off          = Disabled" -ForegroundColor Gray
    Write-Host "    fTPM                   = Disabled (test; skip if Vanguard)" -ForegroundColor Gray
    Write-Host "    Secure Boot            = Standard" -ForegroundColor Gray
    Write-Host "    EXPO / XMP             = Disabled (test)" -ForegroundColor Gray
    Write-Host "    Global C-state Control = Disabled" -ForegroundColor Gray
    Write-Host "    DF Cstates             = Disabled" -ForegroundColor Gray
    Write-Host "    Power Down Enable      = Disabled" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  [After testing, re-enable EXPO with SoC = 1.25V]" -ForegroundColor DarkYellow
    Write-Host ""
    Write-Host "  Press any key to return to menu..." -ForegroundColor Cyan
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# =====================================================
# MAIN LOOP
# =====================================================
Create-RegistryBackup | Out-Null

do {
    Show-Menu
    $choice = Read-Host "  Select option"
    
    switch ($choice) {
        "1"  { Apply-AllTweaks }
        "2"  { Create-RegistryBackup; Tweak-USBDevicePowerManagement }
        "3"  { Create-RegistryBackup; Tweak-MouseSettings }
        "4"  { Create-RegistryBackup; Tweak-KeyboardSettings }
        "5"  { Create-RegistryBackup; Tweak-PriorityControl }
        "6"  { Create-RegistryBackup; Tweak-DWM_MPO }
        "7"  { Create-RegistryBackup; Tweak-GameConfigStore }
        "8"  { Create-RegistryBackup; Tweak-CsrssPriority }
        "9"  { Create-RegistryBackup; Tweak-TimerAndMemory }
        "10" { Create-RegistryBackup; Tweak-PowerManagement }
        "11" { Create-RegistryBackup }
        "12" { Show-BIOSReminder; continue }
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
    
    if ($choice -ne "0" -and $choice -ne "12") {
        Write-Host ""
        Write-Host "  ============================================================" -ForegroundColor Green
        Write-Host "    DONE! RESTART YOUR COMPUTER FOR CHANGES TO APPLY" -ForegroundColor Green
        Write-Host "  ============================================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Registry backup: $Script:BackupPath" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Press any key to continue..." -ForegroundColor Yellow
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
    
} while ($choice -ne "0")

Write-Host ""
Write-Host "  Thanks for using Windows 11 Input Lag Optimizer!" -ForegroundColor Cyan
Write-Host "  Remember to restart your PC." -ForegroundColor Yellow
Write-Host ""
