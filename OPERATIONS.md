# OPERATIONS.md

Runtime notes and validation checklist for the deployed ThinkPad keyboard backlight automation.

---

## Live Findings

These behaviors were confirmed on May 13, 2026 on the current machine:

- The existing scheduled task `ThinkPad Keyboard Backlight` is readable but not mutable in the current user context.
- `schtasks /delete /tn "ThinkPad Keyboard Backlight" /f` returns `Access is denied`.
- `schtasks /create ...` also returns `Access is denied`, so installer updates cannot assume the task can be replaced.
- The installed task action points at `C:\ProgramData\keyboard_backlight.ps1`.
- The machine wakes through Modern Standby and emits `Microsoft-Windows-Kernel-Power` Event ID `507` plus session unlock activity.
- `Microsoft-Windows-Power-Troubleshooter` Event ID `1` is not the primary wake signal here.

---

## Hardened Runtime Layout

Canonical payload directory:

```text
C:\ProgramData\KbBacklight\
  keyboard_backlight.ps1
  kblight.exe
  keyboard_backlight.log
```

Stable bootstrap path:

```text
C:\ProgramData\keyboard_backlight.ps1
```

The bootstrap path exists for two reasons:

1. Older task registrations already point there.
2. Some environments allow file replacement but block task replacement.

The bootstrap calls the canonical script with `-EnsureMonitor`, which does two things:

1. Immediately sets the keyboard backlight using `kblight.exe` with retries.
2. Starts a single hidden per-user PowerShell monitor if one is not already running.

The automation policy is low-only:

- Default automation target: `level 1`
- Maximum automation target: `level 1`
- Any requested automation level above `1` is clamped back to `1`

That monitor listens for:

- `Microsoft.Win32.SystemEvents.PowerModeChanged` resume events
- `Microsoft.Win32.SystemEvents.SessionSwitch` unlock events
- A periodic driver-state poll that restores the light if the hardware reports level `0`

This is the compatibility layer for Modern Standby systems where the scheduled task trigger set cannot be updated, and it now also covers cases where the keyboard backlight falls back to off after the session is already running.

---

## Installer Behavior

`install.ps1` now performs the following in order:

1. Copies the canonical payload to `C:\ProgramData\KbBacklight\`.
2. Rebuilds `kblight.exe` if `kblight.cs` is newer than the bundled binary.
3. Rewrites `C:\ProgramData\keyboard_backlight.ps1` as the stable bootstrap shim.
4. Attempts to register a task that includes logon, unlock, Power-Troubleshooter, and Kernel-Power triggers.
5. If task registration fails with `Access is denied`, it leaves any existing task alone and writes an HKCU Run fallback:

```text
HKCU\Software\Microsoft\Windows\CurrentVersion\Run
  ThinkPad Keyboard Backlight
```

The Run fallback points at the same stable bootstrap path, so the logon behavior stays consistent.

---

## Validation Checklist

Check the driver state:

```powershell
C:\ProgramData\KbBacklight\kblight.exe status
```

Expected shape:

```text
STATUS raw=0x... ready=True level=... max=... preserveBit21=...
```

Run the deployed bootstrap path once:

```powershell
& 'C:\ProgramData\keyboard_backlight.ps1'
```

Tail the runtime log:

```powershell
Get-Content C:\ProgramData\KbBacklight\keyboard_backlight.log -Tail 50
```

Expected log events:

- `success attempt=1 exitCode=0`
- `monitor bootstrap launched`
- `monitor started pid=...`
- `detected off reason=... target=1 raw=...` when the monitor catches an off state and restores it
- `monitor already running` on repeated bootstrap launches

Confirm the background monitor process:

```powershell
Get-CimInstance Win32_Process -Filter "name = 'powershell.exe'" |
  Where-Object { $_.CommandLine -like '*keyboard_backlight.ps1*' } |
  Select-Object ProcessId, CommandLine
```

Confirm the HKCU Run fallback when task updates are blocked:

```powershell
Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'ThinkPad Keyboard Backlight'
```

To shorten the detection interval during manual testing, start the bootstrap with a custom poll interval:

```powershell
& 'C:\ProgramData\KbBacklight\keyboard_backlight.ps1' -EnsureMonitor -MonitorPollIntervalSeconds 5
```

---

## Current Verified State

The following were verified after hardening:

- `C:\ProgramData\KbBacklight\kblight.exe status` returned a ready driver state.
- Running `C:\ProgramData\keyboard_backlight.ps1` restored the backlight to `level 1` successfully when it was off.
- The runtime log recorded successful CLI execution and monitor startup.
- Forcing the hardware to `level 2` and then running the bootstrap left it at `level 2`.
- Re-running the bootstrap did not create duplicate monitors.
- Exactly one hidden PowerShell monitor process remained active.

---

## Removal

`uninstall.ps1` removes:

- `C:\ProgramData\KbBacklight\`
- `C:\ProgramData\keyboard_backlight.ps1`
- The scheduled task names used by current and earlier iterations
- The HKCU Run fallback entry
