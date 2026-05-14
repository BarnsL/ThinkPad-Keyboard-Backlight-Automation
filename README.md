# ThinkPad Keyboard Backlight Automation

Automatically restores the keyboard backlight to low (`level 1`) after startup, unlock, wake, or any later point where the hardware reports the light as off or too bright on ThinkPad laptops running Windows.

ThinkPad keyboards do not persist backlight state across power events. Some systems also let the light drop back to off later in the session. This project fixes that with a stable bootstrap script plus a lightweight hidden per-user monitor that keeps watching the driver state. The automation target is hard-capped at `level 1`, so it will never intentionally restore to `level 2`. There is no tray app and no Lenovo Vantage dependency.

---

## How It Works

The IBM Power Management driver (`IBMPmDrv`) exposes a device at `\\.\IBMPmDrv`. Two `DeviceIoControl` IOCTL codes control the keyboard backlight:

| IOCTL | Decimal | Purpose |
|---|---|---|
| GET | `2238080` | Read current backlight level and hardware capabilities |
| SET | `2238084` | Write a new backlight level |

The GET response is a packed 32-bit integer:
- Bits `3:0` — current level (`0`=off, `1`=low, `2`=high)
- Bits `11:8` — max supported level (typically `2`)
- Bits `19:16` — must equal `0x5` for hardware to be ready
- Bit `21` — flag that must be preserved when constructing the SET argument

SET argument: `(bit21 ? 0x100 : 0) | (GET & 0xF0) | desired_level`

No elevation required. No external DLLs. Works entirely through the kernel driver that ships with Windows on ThinkPad hardware.

The deployed runtime uses a stable bootstrap path at `C:\ProgramData\keyboard_backlight.ps1` that forwards into the canonical install directory `C:\ProgramData\KbBacklight\`. That bootstrap exists so older or protected task registrations keep working even after upgrades.

When Task Scheduler can be updated, the task fires on four triggers:
1. **Logon** — every time the user signs in
2. **Session unlock** — catches interactive wake/unlock flows
3. **System Event ID 1** from `Microsoft-Windows-Power-Troubleshooter` — classic sleep/hibernate resume
4. **System Event ID 507** from `Microsoft-Windows-Kernel-Power` — Modern Standby exit

At logon, the bootstrap also starts a single hidden PowerShell monitor for the user session. That monitor listens for `PowerModeChanged` resume events and `SessionSwitch` unlock events, and it also polls the driver state periodically. If the driver reports level `0` at any point, or reports any level higher than the automation target, the monitor normalizes the light back to `level 1`. This covers machines that wake through Modern Standby but never emit the older Power-Troubleshooter event, and it also handles cases where the backlight goes dark later without a fresh wake event.

---

## Requirements

- Windows 10 or 11
- A ThinkPad with a backlit keyboard
- Lenovo PM Service (`IBMPMSVC`) running — this is installed by default on all ThinkPads
- .NET Framework 4.x (pre-installed on all modern Windows)

---

## Compatible ThinkPad Models

Tested on and confirmed working with models that use the `IBMPmDrv` kernel driver. This includes most ThinkPad T, X, L, E, and P series from roughly 2015 onwards.

**Confirmed working:**
- ThinkPad T14 Gen 2 (20W8)
- ThinkPad X1 Carbon (Gen 6, 7, 8, 9, 10)
- ThinkPad X1 Extreme (Gen 1, 2, 3)
- ThinkPad P1 (Gen 1, 2, 3)
- ThinkPad T480, T480s, T490, T490s, T495
- ThinkPad T14s Gen 1, Gen 2
- ThinkPad X390, X395
- ThinkPad L14, L15 Gen 1, Gen 2
- ThinkPad E14, E15 Gen 2, Gen 3

**Likely compatible** (same driver stack):
- Any ThinkPad T/X/L/E/P series from ~2015 onwards running Windows 10/11
- ThinkPad X13, X13 Yoga
- ThinkPad T15, T15g
- ThinkPad P15, P15s, P17

**Not compatible:**
- ThinkPad models without a backlit keyboard
- Very old models (pre-2014) that use a different PM driver
- IdeaPad / Yoga / Legion (different driver architecture)

To check if your machine is compatible, run in PowerShell:
```powershell
Get-Service IBMPMSVC
```
If it returns `Running`, this tool will work.

---

## Installation

**1. Clone or download this repo**

**2. Build `kblight.exe`** (or use the pre-built binary if provided):
```powershell
C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /out:kblight.exe kblight.cs
```

**3. Run the installer** (no elevation required):
```powershell
.\install.ps1
```

This copies files to `C:\ProgramData\KbBacklight\`, writes the stable bootstrap path at `C:\ProgramData\keyboard_backlight.ps1`, and attempts to register or refresh the scheduled task.

If `schtasks` returns `Access is denied`, the installer keeps any existing task in place and writes an `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` fallback so the same bootstrap still launches at sign-in.

**4. Test it:**
```powershell
schtasks /run /tn "ThinkPad Keyboard Backlight"
Get-Content C:\ProgramData\KbBacklight\keyboard_backlight.log -Tail 20
```

---

## Manual Usage

`kblight.exe` can also be used standalone:

```
kblight.exe 0    # off
kblight.exe 1    # low
kblight.exe 2    # high
kblight.exe status
```

Or from PowerShell directly without compiling — see `keyboard_backlight.ps1` which embeds the same logic inline using `Add-Type`.

The automation script itself defaults to `level 1` and clamps any higher requested automation level back down to `1`, so stale launchers that still pass `-Level 2` are safely normalized.

---

## Uninstall

```powershell
.\uninstall.ps1
```

---

## Files

| File | Purpose |
|---|---|
| `kblight.cs` | C# source for the standalone backlight control tool |
| `kblight.exe` | Compiled CLI used by the scheduled bootstrap and for manual validation |
| `keyboard_backlight.ps1` | PowerShell script run by the scheduled task |
| `install.ps1` | Registers the scheduled task |
| `uninstall.ps1` | Removes the scheduled task and installed files |
| `OPERATIONS.md` | Runtime notes, live validation steps, and troubleshooting commands |

---

## Troubleshooting

Check the live driver state:
```powershell
C:\ProgramData\KbBacklight\kblight.exe status
```

Tail the runtime log:
```powershell
Get-Content C:\ProgramData\KbBacklight\keyboard_backlight.log -Tail 50
```

If you want a faster or slower off-detection loop for manual testing, run the script directly with a custom poll interval:
```powershell
C:\ProgramData\KbBacklight\keyboard_backlight.ps1 -EnsureMonitor -MonitorPollIntervalSeconds 5
```

If the light is manually pushed to `level 2`, the next bootstrap run or monitor pass will drive it back down to `level 1`.

Confirm the hidden monitor process is running:
```powershell
Get-CimInstance Win32_Process -Filter "name = 'powershell.exe'" |
	Where-Object { $_.CommandLine -like '*keyboard_backlight.ps1*' } |
	Select-Object ProcessId, CommandLine
```

Inspect the current task registration:
```powershell
Get-ScheduledTask -TaskName "ThinkPad Keyboard Backlight" |
	Select-Object TaskName, State, @{N='Arguments';E={$_.Actions.Arguments}}
```

If your machine uses Modern Standby and never emits `Power-Troubleshooter` Event ID 1, that is expected. The per-user monitor is the compatibility layer that keeps wake handling working on those systems. See `OPERATIONS.md` for the live diagnosis and fallback behavior.

---

## Research Notes

Getting here took significant reverse engineering. A full writeup of every approach tried (WMI, window messages, named pipes, DLL injection, raw scancode injection, etc.) and why they failed is in [`RESEARCH.md`](RESEARCH.md).

**TL;DR of what doesn't work:**
- `SendInput` / scancode injection — `tphkload` runs in Session 0, unreachable
- `Lenovo_SetFunctionRequest` WMI — requires elevation + correct string format unknown
- Named pipe `ShortcutKey` — server-only, cannot connect as client
- `rainbow.dll` direct call — requires HID device handle initialization
- Window messages to `shtctky.exe` — not the IPC mechanism used

**What works:** `DeviceIoControl` on `\\.\IBMPmDrv` — discovered via [pspatel321/auto-backlight-for-thinkpad](https://github.com/pspatel321/auto-backlight-for-thinkpad). The repo now layers a stable bootstrap path, retries, logging, and a hidden per-user wake monitor on top of that control method.

---

## Credits

- Control method: [pspatel321/auto-backlight-for-thinkpad](https://github.com/pspatel321/auto-backlight-for-thinkpad)
- Additional reference: [ligius-/lenovo-backlight-control](https://github.com/ligius-/lenovo-backlight-control)
