# uninstall.ps1
# Removes the scheduled task, installed files, and the legacy compatibility shim.

$taskNames = @(
	"ThinkPad Keyboard Backlight",
	"ThinkPad Keyboard Backlight Automation",
	"HP EliteBook Keyboard Backlight",
	"HP Keyboard Backlight Automation"
)
$installDir = "C:\ProgramData\KbBacklight"
$legacyScriptPath = "C:\ProgramData\keyboard_backlight.ps1"
$runKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$runValueNames = @(
	"ThinkPad Keyboard Backlight",
	"HP EliteBook Keyboard Backlight"
)

foreach ($taskName in $taskNames) {
	schtasks /delete /tn $taskName /f 2>$null | Out-Null
}

if (Test-Path $installDir) {
	Remove-Item $installDir -Recurse -Force
}

if (Test-Path $legacyScriptPath) {
	Remove-Item $legacyScriptPath -Force
}

foreach ($runValueName in $runValueNames) {
	Remove-ItemProperty -Path $runKeyPath -Name $runValueName -ErrorAction SilentlyContinue
}

Write-Host "Uninstalled."
