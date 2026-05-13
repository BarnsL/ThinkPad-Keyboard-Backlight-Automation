# install.ps1
#
# Installs the ThinkPad Keyboard Backlight Automation scheduled task.
# Run this once from the project directory. No elevation required.
#
# What it does:
#   1. Copies keyboard_backlight.ps1 and kblight.exe to C:\ProgramData\KbBacklight\
#   2. Compiles kblight.cs if kblight.exe is not already present
#   3. Registers a scheduled task that fires on:
#        - Logon
#        - Resume from sleep (System Event ID 1, Power-Troubleshooter)

$installDir = "C:\ProgramData\KbBacklight"
$taskName   = "ThinkPad Keyboard Backlight"
$scriptSrc  = Join-Path $PSScriptRoot "keyboard_backlight.ps1"
$exeSrc     = Join-Path $PSScriptRoot "kblight.exe"
$csSrc      = Join-Path $PSScriptRoot "kblight.cs"

# Create install directory
if (-not (Test-Path $installDir)) { New-Item -ItemType Directory -Path $installDir | Out-Null }

# Compile kblight.exe if not already built
if (-not (Test-Path $exeSrc)) {
    Write-Host "Compiling kblight.exe..."
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    & $csc /out:$exeSrc $csSrc
    if ($LASTEXITCODE -ne 0) { Write-Error "Compilation failed"; exit 1 }
}

# Copy files
Copy-Item $scriptSrc "$installDir\keyboard_backlight.ps1" -Force
Copy-Item $exeSrc    "$installDir\kblight.exe"            -Force
Write-Host "Files copied to $installDir"

# Remove existing task if present
schtasks /delete /tn $taskName /f 2>$null | Out-Null

# Write task XML
$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Restores keyboard backlight to ON after logon or resume from sleep.</Description>
    <URI>\$taskName</URI>
  </RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <UserId>$([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)</UserId>
      <LogonType>InteractiveToken</LogonType>
    </Principal>
  </Principals>
  <Settings>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <ExecutionTimeLimit>PT1M</ExecutionTimeLimit>
  </Settings>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
    </LogonTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query&gt;&lt;Select Path='System'&gt;*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File "$installDir\keyboard_backlight.ps1"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

$xmlPath = "$env:TEMP\kbbacklight_task.xml"
$taskXml | Out-File $xmlPath -Encoding Unicode
schtasks /create /tn $taskName /xml $xmlPath /f
Remove-Item $xmlPath

Write-Host ""
Write-Host "Done. Task '$taskName' registered."
Write-Host "To test: schtasks /run /tn `"$taskName`""
Write-Host "To remove: schtasks /delete /tn `"$taskName`" /f"
