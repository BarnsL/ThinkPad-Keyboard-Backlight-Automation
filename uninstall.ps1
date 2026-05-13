# uninstall.ps1
# Removes the scheduled task and installed files.

$taskName  = "ThinkPad Keyboard Backlight"
$installDir = "C:\ProgramData\KbBacklight"

schtasks /delete /tn $taskName /f 2>&1
if (Test-Path $installDir) { Remove-Item $installDir -Recurse -Force }
Write-Host "Uninstalled."
