# keyboard_backlight.ps1
#
# Restores the ThinkPad keyboard backlight after logon, unlock, or resume.
# The scheduled task prefers kblight.exe for the actual DeviceIoControl call and
# falls back to the inline implementation below if the CLI is missing.

param(
    [ValidateRange(0, 2)]
    [int]$Level = 2,

    [ValidateRange(0, 30)]
    [int]$InitialDelaySeconds = 2,

    [ValidateRange(1, 12)]
    [int]$MaxAttempts = 8,

    [ValidateRange(1, 30)]
    [int]$RetryDelaySeconds = 2,

    [switch]$Monitor,

    [switch]$EnsureMonitor
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$scriptPath = if ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { Join-Path $scriptDir "keyboard_backlight.ps1" }
$cliPath = Join-Path $scriptDir "kblight.exe"
$logPath = Join-Path $scriptDir "keyboard_backlight.log"
$monitorMutexName = "Local\ThinkPadKeyboardBacklightMonitor"

if ((Test-Path $logPath) -and ((Get-Item $logPath).Length -gt 262144)) {
    Move-Item $logPath "$logPath.1" -Force
}

function Write-BacklightLog {
    param([string]$Message)

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logPath -Value "$timestamp $Message" -Encoding UTF8
}

function Ensure-InlineBacklightType {
    if ('ThinkPadKeyboardBacklight.NativeMethods' -as [type]) {
        return
    }

    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace ThinkPadKeyboardBacklight {
    public static class NativeMethods {
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool DeviceIoControl(IntPtr h, uint code, byte[] inBuf, uint inSize, byte[] outBuf, uint outSize, out uint returned, ref NativeOverlapped ov);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool CloseHandle(IntPtr h);

        private const uint IoctlGet = 2238080;
        private const uint IoctlSet = 2238084;

        private static int CallPm(uint code, int input) {
            IntPtr h = CreateFile(@"\\.\IBMPmDrv", 0x80000000, 1, IntPtr.Zero, 3, 0, IntPtr.Zero);
            if (h == IntPtr.Zero || h.ToInt64() == -1)
                throw new Exception("Cannot open IBMPmDrv (error " + Marshal.GetLastWin32Error() + ")");

            byte[] inp = BitConverter.GetBytes(input);
            byte[] outp = new byte[4];
            uint ret = 0;
            NativeOverlapped ov = new NativeOverlapped();
            bool ok = DeviceIoControl(h, code, inp, (uint)inp.Length, outp, (uint)outp.Length, out ret, ref ov);
            CloseHandle(h);
            if (!ok)
                throw new Exception("DeviceIoControl failed (error " + Marshal.GetLastWin32Error() + ")");

            return BitConverter.ToInt32(outp, 0);
        }

        public static void SetLevel(int level) {
            int state = CallPm(IoctlGet, 0);
            if ((state & 0x0050000) != 0x0050000)
                throw new Exception("Backlight hardware not ready (GET=0x" + state.ToString("X") + ")");

            int arg = ((state & 0x00200000) != 0 ? 0x100 : 0) | (state & 0xF0) | level;
            int result = CallPm(IoctlSet, arg);
            if (result != 0)
                throw new Exception("Driver returned non-zero status " + result);
        }
    }
}
"@
}

function Invoke-InlineBacklight {
    param([int]$TargetLevel)

    Ensure-InlineBacklightType
    [ThinkPadKeyboardBacklight.NativeMethods]::SetLevel($TargetLevel)
}

function Invoke-KbBacklight {
    param([int]$TargetLevel)

    if (Test-Path $cliPath) {
        $output = & $cliPath $TargetLevel 2>&1
        $exitCode = $LASTEXITCODE

        if ($null -ne $output) {
            foreach ($line in $output) {
                Write-BacklightLog "cli $line"
            }
        }

        if ($exitCode -eq 0) {
            return 0
        }

        throw "kblight.exe exited with code $exitCode"
    }

    Invoke-InlineBacklight -TargetLevel $TargetLevel
    Write-BacklightLog "inline set level=$TargetLevel"
    return 0
}

function Invoke-BacklightAction {
    param([int]$TargetLevel)

    Write-BacklightLog "start level=$TargetLevel initialDelay=$InitialDelaySeconds attempts=$MaxAttempts retryDelay=$RetryDelaySeconds script=$scriptPath"

    if ($InitialDelaySeconds -gt 0) {
        Start-Sleep -Seconds $InitialDelaySeconds
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $exitCode = Invoke-KbBacklight -TargetLevel $TargetLevel
            Write-BacklightLog "success attempt=$attempt exitCode=$exitCode"
            return 0
        } catch {
            Write-BacklightLog "retry attempt=$attempt error=$($_.Exception.Message)"
            if ($attempt -lt $MaxAttempts) {
                Start-Sleep -Seconds $RetryDelaySeconds
            }
        }
    }

    Write-BacklightLog "failed level=$TargetLevel afterAttempts=$MaxAttempts"
    return 1
}

function Test-MonitorRunning {
    try {
        $mutex = [System.Threading.Mutex]::OpenExisting($monitorMutexName)
        $mutex.Dispose()
        return $true
    } catch [System.Threading.WaitHandleCannotBeOpenedException] {
        return $false
    }
}

function Start-BacklightMonitor {
    param([int]$TargetLevel)

    $argumentList = @(
        "-Sta",
        "-NoProfile",
        "-ExecutionPolicy Bypass",
        ('-File "{0}"' -f $scriptPath),
        "-Monitor",
        ('-Level {0}' -f $TargetLevel),
        ('-InitialDelaySeconds {0}' -f $InitialDelaySeconds),
        ('-MaxAttempts {0}' -f $MaxAttempts),
        ('-RetryDelaySeconds {0}' -f $RetryDelaySeconds)
    ) -join " "

    Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList $argumentList | Out-Null
}

function Start-MonitorLoop {
    $createdNew = $false
    $monitorMutex = New-Object System.Threading.Mutex($true, $monitorMutexName, [ref]$createdNew)
    if (-not $createdNew) {
        Write-BacklightLog "monitor already active; exiting duplicate bootstrap"
        $monitorMutex.Dispose()
        return 0
    }

    $powerSource = "ThinkPadKeyboardBacklight.Power.$PID"
    $sessionSource = "ThinkPadKeyboardBacklight.Session.$PID"

    try {
        Write-BacklightLog "monitor started pid=$PID"
        [void](Invoke-BacklightAction -TargetLevel $Level)
        Register-ObjectEvent -InputObject ([Microsoft.Win32.SystemEvents]) -EventName PowerModeChanged -SourceIdentifier $powerSource | Out-Null
        Register-ObjectEvent -InputObject ([Microsoft.Win32.SystemEvents]) -EventName SessionSwitch -SourceIdentifier $sessionSource | Out-Null

        while ($true) {
            $event = Wait-Event -Timeout 3600
            if ($null -eq $event) {
                continue
            }

            try {
                if ($event.SourceIdentifier -eq $powerSource -and $event.SourceEventArgs.Mode -eq [Microsoft.Win32.PowerModes]::Resume) {
                    Write-BacklightLog "monitor event=resume"
                    [void](Invoke-BacklightAction -TargetLevel $Level)
                } elseif ($event.SourceIdentifier -eq $sessionSource -and $event.SourceEventArgs.Reason -eq [Microsoft.Win32.SessionSwitchReason]::SessionUnlock) {
                    Write-BacklightLog "monitor event=session-unlock"
                    [void](Invoke-BacklightAction -TargetLevel $Level)
                }
            } catch {
                Write-BacklightLog "monitor error=$($_.Exception.Message)"
            } finally {
                Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue
            }
        }
    } finally {
        Unregister-Event -SourceIdentifier $powerSource -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier $sessionSource -ErrorAction SilentlyContinue
        if ($null -ne $monitorMutex) {
            $monitorMutex.ReleaseMutex()
            $monitorMutex.Dispose()
        }
    }
}

if ($Monitor) {
    exit (Start-MonitorLoop)
}

if ($EnsureMonitor) {
    $exitCode = Invoke-BacklightAction -TargetLevel $Level
    if (-not (Test-MonitorRunning)) {
        Start-BacklightMonitor -TargetLevel $Level
        Write-BacklightLog "monitor bootstrap launched"
    } else {
        Write-BacklightLog "monitor already running"
    }
    if ($exitCode -eq 0) {
        exit 0
    }
    exit 1
}

exit (Invoke-BacklightAction -TargetLevel $Level)
