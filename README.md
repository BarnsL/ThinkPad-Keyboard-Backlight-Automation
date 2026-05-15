# Windows Keyboard Backlight Automation

Automates keyboard backlight behavior on Windows for:

- Lenovo ThinkPad systems using the documented `IBMPmDrv` device interface.
- HP EliteBook systems (including Poly Studio variants) using documented HP BIOS automation surfaces (HP CMSL and HP Instrumented BIOS WMI fallback).

---

## Platform Matrix

| Platform | Runtime | Immediate level control | Persistence control |
|---|---|---|---|
| ThinkPad | `keyboard_backlight.ps1` + `kblight.exe` | Yes (`0/1/2`) | Yes (monitor + task triggers) |
| HP EliteBook / Poly Studio | `hp_keyboard_backlight.ps1` | No documented direct runtime API | Yes (BIOS keyboard backlight setting automation) |

Important: HP support in this repository intentionally uses documented interfaces only. On many EliteBook models, public tooling exposes keyboard backlight timeout/enable policy, not an immediate on-demand brightness level API equivalent to ThinkPad `IBMPmDrv`.

---

## What Is Already Documented For HP

The current documented vendor path for HP automation is HP CMSL (Client Management Script Library):

- BIOS and Device module exposes `Get-HPBIOSSettingsList` and `Set-HPBIOSSettingValue`.
- This allows discovery and setting of BIOS attributes, including keyboard backlight-related settings where available on the specific model.

Reference pages checked:

- https://developers.hp.com/hp-client-management/doc/client-management-script-library
- https://developers.hp.com/hp-client-management/doc/bios-and-device

This repository implements that documented route first, then falls back to HP Instrumented BIOS WMI (`root\HP\InstrumentedBIOS`) when CMSL cmdlets are unavailable.

---

## How It Works

### ThinkPad path

ThinkPad control uses `DeviceIoControl` against `\\.\IBMPmDrv`:

| IOCTL | Decimal | Purpose |
|---|---|---|
| GET | `2238080` | Read current backlight state/capabilities |
| SET | `2238084` | Set desired backlight level |

The scheduled bootstrap starts a single hidden monitor that reacts to resume/unlock/poll events and restores from off (`0`) to low (`1`) when needed.

### HP EliteBook path

HP control is implemented as a best-effort BIOS setting apply routine:

1. Detect keyboard backlight related BIOS settings via HP CMSL.
2. Select a persistence-oriented value (`Never`, `Always On`, `Enabled`, or longest timeout available).
3. Apply with `Set-HPBIOSSettingValue`.
4. If CMSL is unavailable, fall back to `root\HP\InstrumentedBIOS` classes.

The same scheduler triggers (logon/unlock/resume) are used so settings are re-applied after common power transitions.

---

## Requirements

- Windows 10 or 11
- PowerShell 5.1+ (default on supported Windows)
- For ThinkPad: Lenovo PM service (`IBMPMSVC`) and .NET Framework 4.x
- For HP EliteBook: HP CMSL recommended (`Get-HPBIOSSettingsList` / `Set-HPBIOSSettingValue`), with WMI fallback

---

## Installation

Run installer with auto-detection:

```powershell
.\install.ps1
```

Or force a platform:

```powershell
.\install.ps1 -Platform ThinkPad
.\install.ps1 -Platform HpEliteBook
```

Installer behavior:

1. Copies payloads to `C:\ProgramData\KbBacklight\`.
2. Builds `kblight.exe` when needed for ThinkPad path.
3. Writes stable bootstrap `C:\ProgramData\keyboard_backlight.ps1`.
4. Registers a scheduled task for logon, unlock, and resume events.
5. Falls back to `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` if task update is blocked.

---

## Testing

### Common checks

```powershell
schtasks /run /tn "ThinkPad Keyboard Backlight"
schtasks /run /tn "HP EliteBook Keyboard Backlight"
Get-Content C:\ProgramData\KbBacklight\keyboard_backlight.log -Tail 50
```

### ThinkPad checks

```powershell
C:\ProgramData\KbBacklight\kblight.exe status
& 'C:\ProgramData\KbBacklight\keyboard_backlight.ps1' -EnsureMonitor
```

Expected logs include `success attempt=...` and monitor lifecycle events.

### HP EliteBook checks

Verify CMSL cmdlets:

```powershell
Get-Command Get-HPBIOSSettingsList, Set-HPBIOSSettingValue
```

Run HP routine directly:

```powershell
& 'C:\ProgramData\KbBacklight\hp_keyboard_backlight.ps1' -EnsureMonitor
```

Expected logs include one of:

- `success via hp-cmsl`
- `success via hp-wmi-fallback`

If BIOS settings are locked by setup password, log entries will show apply failures and no setting changes.

---

## Uninstall

```powershell
.\uninstall.ps1
```

---

## Files

| File | Purpose |
|---|---|
| `keyboard_backlight.ps1` | ThinkPad runtime script with monitor loop |
| `hp_keyboard_backlight.ps1` | HP EliteBook runtime script (CMSL/WMI based) |
| `kblight.cs` | ThinkPad CLI source (`IBMPmDrv`) |
| `install.ps1` | Auto-detecting platform installer |
| `uninstall.ps1` | Removes both ThinkPad and HP task variants |
| `OPERATIONS.md` | Process and test checklist |
| `RESEARCH.md` | Reverse engineering and vendor research notes |

---

## Research Notes

Detailed ThinkPad reverse engineering plus HP documentation path checks are in `RESEARCH.md`.

---

## Credits

- ThinkPad control method: [pspatel321/auto-backlight-for-thinkpad](https://github.com/pspatel321/auto-backlight-for-thinkpad)
- Additional ThinkPad reference: [ligius-/lenovo-backlight-control](https://github.com/ligius-/lenovo-backlight-control)
- HP management documentation: HP Client Management Script Library (CMSL)
