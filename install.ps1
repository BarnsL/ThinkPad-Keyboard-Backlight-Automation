# install.ps1
#
# Installs or repairs the ThinkPad Keyboard Backlight scheduled task.
# Run this once from the project directory. No elevation required.
#
# What it does:
#   1. Copies keyboard_backlight.ps1 and kblight.exe to C:\ProgramData\KbBacklight\
#   2. Rebuilds kblight.exe when kblight.cs is newer than the bundled binary
#   3. Writes a compatibility shim to C:\ProgramData\keyboard_backlight.ps1
#   4. Registers a scheduled task when policy allows it, otherwise configures
#      an HKCU Run fallback that starts the same bootstrap path at logon
#   5. Boots a lightweight per-user resume monitor from the logon path so
#      Modern Standby wake events are covered even when Task Scheduler cannot
#      be updated in-place
#
# The canonical launch path is C:\ProgramData\keyboard_backlight.ps1 so older
# protected task registrations keep working after upgrades.
#
# When task registration is allowed, the task fires on:
#        - Logon
#        - Session unlock
#        - Classic resume (Power-Troubleshooter Event ID 1)
#        - Modern Standby exit (Kernel-Power Event ID 507)

$installDir = "C:\ProgramData\KbBacklight"
$taskName = "ThinkPad Keyboard Backlight"
$legacyTaskNames = @("ThinkPad Keyboard Backlight Automation")
$scriptSrc = Join-Path $PSScriptRoot "keyboard_backlight.ps1"
$exeSrc = Join-Path $PSScriptRoot "kblight.exe"
$csSrc = Join-Path $PSScriptRoot "kblight.cs"
$installedScriptPath = Join-Path $installDir "keyboard_backlight.ps1"
$installedExePath = Join-Path $installDir "kblight.exe"
$legacyScriptPath = "C:\ProgramData\keyboard_backlight.ps1"
$currentUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$runKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$runValueName = "ThinkPad Keyboard Backlight"
$runCommand = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$legacyScriptPath`""

if (-not (Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir | Out-Null
}

$shouldCompile = -not (Test-Path $exeSrc)
if (-not $shouldCompile -and (Test-Path $csSrc)) {
    $shouldCompile = (Get-Item $csSrc).LastWriteTimeUtc -gt (Get-Item $exeSrc).LastWriteTimeUtc
}

if ($shouldCompile) {
    Write-Host "Compiling kblight.exe..."
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    & $csc /out:$exeSrc $csSrc
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Compilation failed"
        exit 1
    }
}

Copy-Item $scriptSrc $installedScriptPath -Force
Copy-Item $exeSrc $installedExePath -Force

$legacyShim = @"
# Compatibility shim for older task registrations that pointed at
# C:\ProgramData\keyboard_backlight.ps1 instead of the canonical install dir.


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
Write-Host "Legacy compatibility shim written to $legacyScriptPath"

$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Restores keyboard backlight to ON after logon, unlock, or resume.</Description>
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
    <ExecutionTimeLimit>PT1M</ExecutionTimeLimit>
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
  schtasks /create /tn $taskName /xml $xmlPath /f | Out-Null
  if ($LASTEXITCODE -eq 0) {
    $taskRegistered = $true
  }

  foreach ($name in $legacyTaskNames) {
    schtasks /delete /tn $name /f 2>$null | Out-Null
}
Remove-Item $xmlPath

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
Write-Host "Installed CLI:    $installedExePath"
  Write-Host "Bootstrap path:   $legacyScriptPath"
Write-Host "To test: schtasks /run /tn `"$taskName`""
Write-Host "To tail logs: Get-Content `"$installDir\keyboard_backlight.log`" -Tail 20"
