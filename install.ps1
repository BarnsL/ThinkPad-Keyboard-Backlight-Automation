# install.ps1
#
# Installs keyboard backlight automation for:
#   - Lenovo ThinkPad (IBMPmDrv runtime)
#   - HP EliteBook (HP CMSL/WMI BIOS setting runtime)
#
# Run from the project directory. No elevation required.

param(
    [ValidateSet("Auto", "ThinkPad", "HpEliteBook")]
    [string]$Platform = "Auto"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$installDir = "C:\ProgramData\KbBacklight"
$legacyScriptPath = "C:\ProgramData\keyboard_backlight.ps1"
$currentUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$runKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"

$thinkPadScriptSrc = Join-Path $PSScriptRoot "keyboard_backlight.ps1"
$hpScriptSrc = Join-Path $PSScriptRoot "hp_keyboard_backlight.ps1"
$exeSrc = Join-Path $PSScriptRoot "kblight.exe"
$csSrc = Join-Path $PSScriptRoot "kblight.cs"

function Get-DetectedPlatform {
    param([string]$RequestedPlatform)

    if ($RequestedPlatform -ne "Auto") {
        return $RequestedPlatform
    }

    $system = Get-CimInstance Win32_ComputerSystem
    $manufacturer = [string]$system.Manufacturer
    $model = [string]$system.Model

    if ($manufacturer -match "(?i)lenovo" -or (Get-Service IBMPMSVC -ErrorAction SilentlyContinue)) {
        return "ThinkPad"
    }

    if ($manufacturer -match "(?i)hp|hewlett-packard") {
        if ($model -match "(?i)elitebook") {
            return "HpEliteBook"
        }
    }

    throw "Unsupported platform for Auto detection. Manufacturer='$manufacturer', Model='$model'. Use -Platform ThinkPad or -Platform HpEliteBook explicitly."
}

function Update-ThinkPadCli {
    $shouldCompile = -not (Test-Path $exeSrc)
    if (-not $shouldCompile -and (Test-Path $csSrc)) {
        $shouldCompile = (Get-Item $csSrc).LastWriteTimeUtc -gt (Get-Item $exeSrc).LastWriteTimeUtc
    }

    if ($shouldCompile) {
        Write-Host "Compiling kblight.exe..."
        $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
        & $csc /out:$exeSrc $csSrc
        if ($LASTEXITCODE -ne 0) {
            throw "Compilation failed"
        }
    }
}

$resolvedPlatform = Get-DetectedPlatform -RequestedPlatform $Platform

switch ($resolvedPlatform) {
    "ThinkPad" {
        $taskName = "ThinkPad Keyboard Backlight"
        $legacyTaskNames = @("ThinkPad Keyboard Backlight Automation")
        $runValueName = "ThinkPad Keyboard Backlight"
        $canonicalScriptName = "keyboard_backlight.ps1"
        Update-ThinkPadCli
    }
    "HpEliteBook" {
        $taskName = "HP EliteBook Keyboard Backlight"
        $legacyTaskNames = @("HP Keyboard Backlight Automation")
        $runValueName = "HP EliteBook Keyboard Backlight"
        $canonicalScriptName = "hp_keyboard_backlight.ps1"
    }
    default {
        throw "Unsupported platform '$resolvedPlatform'"
    }
}

$runCommand = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$legacyScriptPath`""

if (-not (Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir | Out-Null
}

Copy-Item $thinkPadScriptSrc (Join-Path $installDir "keyboard_backlight.ps1") -Force
Copy-Item $hpScriptSrc (Join-Path $installDir "hp_keyboard_backlight.ps1") -Force
if (Test-Path $exeSrc) {
    Copy-Item $exeSrc (Join-Path $installDir "kblight.exe") -Force
}

$installedScriptPath = Join-Path $installDir $canonicalScriptName
$installedExePath = Join-Path $installDir "kblight.exe"

$legacyShim = @"
# Compatibility shim for task registrations that point to
# C:\ProgramData\keyboard_backlight.ps1.

`$canonicalScript = '$installedScriptPath'
if (-not (Test-Path `$canonicalScript)) {
    Write-Error "Canonical keyboard backlight script not found at `$canonicalScript"
    exit 1
}

& `$canonicalScript -EnsureMonitor
exit `$LASTEXITCODE
"@
$legacyShim | Out-File $legacyScriptPath -Encoding ASCII -Force

Write-Host "Files copied to $installDir"
Write-Host "Platform: $resolvedPlatform"
Write-Host "Legacy compatibility shim written to $legacyScriptPath"

$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Restores keyboard backlight automation settings after logon, unlock, or resume.</Description>
    <URI>\$taskName</URI>
  </RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <UserId>$currentUserSid</UserId>
      <LogonType>InteractiveToken</LogonType>
    </Principal>
  </Principals>
  <Settings>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <ExecutionTimeLimit>PT2M</ExecutionTimeLimit>
    <StartWhenAvailable>true</StartWhenAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
  </Settings>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
    </LogonTrigger>
    <SessionStateChangeTrigger>
      <Enabled>true</Enabled>
      <UserId>$currentUserSid</UserId>
      <StateChange>SessionUnlock</StateChange>
    </SessionStateChangeTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query&gt;&lt;Select Path='System'&gt;*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query&gt;&lt;Select Path='System'&gt;*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and EventID=507]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File $legacyScriptPath</Arguments>
    </Exec>
  </Actions>
</Task>
"@

$xmlPath = Join-Path $env:TEMP "kbbacklight_task.xml"
$taskXml | Out-File $xmlPath -Encoding Unicode

$taskRegistered = $false
try {
    schtasks /create /tn $taskName /xml $xmlPath /f | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $taskRegistered = $true
    }
} finally {
    Remove-Item $xmlPath -ErrorAction SilentlyContinue
}

foreach ($name in $legacyTaskNames) {
    schtasks /delete /tn $name /f 2>$null | Out-Null
}

if (-not $taskRegistered) {
    Write-Warning "Task registration could not be updated in this user context. Keeping any existing task and configuring an HKCU Run fallback."
    New-Item -Path $runKeyPath -Force | Out-Null
    New-ItemProperty -Path $runKeyPath -Name $runValueName -Value $runCommand -PropertyType String -Force | Out-Null
} else {
    Remove-ItemProperty -Path $runKeyPath -Name $runValueName -ErrorAction SilentlyContinue
    $registeredArguments = (Get-ScheduledTask -TaskName $taskName).Actions[0].Arguments
    if ($registeredArguments -notlike "*$legacyScriptPath*") {
        Write-Warning "Registered task arguments differ from the stable bootstrap path: $registeredArguments"
    }
}

Write-Host ""
if ($taskRegistered) {
    Write-Host "Done. Task '$taskName' registered."
} else {
    Write-Host "Done. Existing bootstrap preserved; HKCU Run fallback configured."
}

Write-Host "Installed script: $installedScriptPath"
if ($resolvedPlatform -eq "ThinkPad") {
    Write-Host "Installed CLI:    $installedExePath"
}
Write-Host "Bootstrap path:   $legacyScriptPath"
Write-Host "To test: schtasks /run /tn `"$taskName`""
Write-Host "To tail logs: Get-Content `"$installDir\keyboard_backlight.log`" -Tail 20"
