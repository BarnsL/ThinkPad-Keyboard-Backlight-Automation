# ThinkPad Keyboard Backlight Automation

Automatically restores the keyboard backlight to ON after every startup and resume from sleep on ThinkPad laptops running Windows.

ThinkPad keyboards do not persist backlight state across power events. This project fixes that with a lightweight scheduled task — no background process, no tray app, no Lenovo Vantage required.

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

The scheduled task fires on two triggers:
1. **Logon** — every time the user signs in
2. **System Event ID 1** from `Microsoft-Windows-Power-Troubleshooter` — every resume from sleep or hibernate

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

This copies files to `C:\ProgramData\KbBacklight\` and registers the scheduled task.

**4. Test it:**
```powershell
schtasks /run /tn "ThinkPad Keyboard Backlight"
```

---

## Manual Usage

`kblight.exe` can also be used standalone:

```
kblight.exe 0    # off
kblight.exe 1    # low
kblight.exe 2    # high
```

Or from PowerShell directly without compiling — see `keyboard_backlight.ps1` which embeds the same logic inline using `Add-Type`.

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
| `keyboard_backlight.ps1` | PowerShell script run by the scheduled task |
| `install.ps1` | Registers the scheduled task |
| `uninstall.ps1` | Removes the scheduled task and installed files |

---

## Research Notes

Getting here took significant reverse engineering. A full writeup of every approach tried (WMI, window messages, named pipes, DLL injection, raw scancode injection, etc.) and why they failed is in [`RESEARCH.md`](RESEARCH.md).

**TL;DR of what doesn't work:**
- `SendInput` / scancode injection — `tphkload` runs in Session 0, unreachable
- `Lenovo_SetFunctionRequest` WMI — requires elevation + correct string format unknown
- Named pipe `ShortcutKey` — server-only, cannot connect as client
- `rainbow.dll` direct call — requires HID device handle initialization
- Window messages to `shtctky.exe` — not the IPC mechanism used

**What works:** `DeviceIoControl` on `\\.\IBMPmDrv` — discovered via [pspatel321/auto-backlight-for-thinkpad](https://github.com/pspatel321/auto-backlight-for-thinkpad).

---

## Credits

- Control method: [pspatel321/auto-backlight-for-thinkpad](https://github.com/pspatel321/auto-backlight-for-thinkpad)
- Additional reference: [ligius-/lenovo-backlight-control](https://github.com/ligius-/lenovo-backlight-control)
