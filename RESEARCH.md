# RESEARCH.md — ThinkPad Keyboard Backlight Automation

Full notes on every approach tried to automate the ThinkPad keyboard backlight on Windows, what failed, and what ultimately worked.

Update (May 2026): this repository also includes HP EliteBook (Poly Studio-capable models) support through documented HP BIOS automation interfaces. See HP section near the end.

---

## System Architecture

```
Physical Fn+Space keypress
        ↓
ACPI EC (Embedded Controller) → ACPI\LEN0130 device
        ↓
tphkload.exe (Session 0, SYSTEM) — owns the ACPI device
  loads: SHTCTKY.DLL, TPOSD.DLL, mmstate.dll, smm10.dll
        ↓  (named pipe IPC)
shtctky.exe (Session 1, user) — receives hotkey event
        ↓
rainbow.dll — hardware backlight control (requires HID device handle)
        ↓
tposd.exe — shows OSD animation on screen
```

Key insight: `tphkload.exe` runs in **Session 0** (SYSTEM). Any approach that requires interacting with its loaded DLLs from a user process faces a session boundary.

---

## What Was Tried

### ❌ SendInput / Raw Scancode Injection
Injected scancode `0x71` via `SendInput` with `KEYEVENTF_SCANCODE`.  
**Fail:** `SendInput` cannot cross the Session 0 boundary to reach `tphkload`.

### ❌ Lenovo WMI — `Lenovo_SetFunctionRequest`
Method exists, takes a `String` parameter named `parameter`, has a `String` out-param named `return`.  
Tried 25+ string formats: `Ex_31`, `Ex_31,1`, `Ex_31,2`, `KBLT`, `KbdBacklight,2`, `0x31`, `49`, etc.  
**Fail:** All returned `Invalid method Parameter(s)`. Instance access requires elevation and the correct string format was never found.

### ❌ Lenovo WMI — `Lenovo_SetPlatformSetting`
Same signature as above.  
**Fail:** Access denied without elevation; correct parameter format unknown.

### ❌ Window Messages to `shtctky.exe`
`shtctky.exe` has a hidden window with class `{EE79C473-8AFB-40a5-9E35-0F66CF6B4A8E}`.  
Tried `WM_APP` range `0x8000`–`0x8200`, `WM_USER` range, and 13 `RegisterWindowMessage` name strings.  
**Fail:** All returned 0, no backlight change. Window messages are not the IPC mechanism.

### ❌ Named Pipe — ShortcutKey
Found pipe: `{C6A9690C-33AE-4a55-8B65-9498CC0A7B34}.0FE6F926-...ShortcutKey`  
Attempted `NamedPipeClientStream` connection sending keycode `0x31` as DWORD.  
**Fail:** `The semaphore timeout period has expired` — pipe is server-only (`tphkload` writes, `shtctky` reads).

### ❌ `rainbow.dll` Direct Call
`rainbow.dll` has 20 ordinal exports. Loaded cold and tried calling ordinals 1–20 with `Cdecl`/`StdCall`, 0–3 args.  
**Fail:** `AccessViolationException` on all — DLL requires initialization with a HID device handle set up by `tphkload`.

### ❌ `CreateRemoteThread` into `shtctky.exe`
Attempted to call `rainbow.dll` ordinals from within `shtctky.exe`'s process.  
**Fail:** `rainbow.dll` is not loaded in `shtctky.exe` — it's in `tphkload.exe` (Session 0).

### ❌ `Keyboard_Core.dll` via Lenovo ImController
`ligius-/lenovo-backlight-control` uses `Keyboard_Core.KeyboardControl.SetKeyboardBackLightStatus()` from Lenovo's ImController plugin.  
**Fail:** ImController / Lenovo System Interface Foundation not installed on this machine.

---

## ✅ What Works — `IBMPmDrv` DeviceIoControl

Discovered via [pspatel321/auto-backlight-for-thinkpad](https://github.com/pspatel321/auto-backlight-for-thinkpad).

The IBM Power Management driver exposes `\\.\IBMPmDrv`. Two IOCTLs:

```
GET  2238080  →  packed int: bits[3:0]=level, bits[11:8]=maxLevel, bits[19:16]=0x5 if ready
SET  2238084  ←  arg = (bit21_flag ? 0x100 : 0) | (GET & 0xF0) | desired_level
```

No elevation. No external DLLs. Works from any user process as long as `IBMPMSVC` is running.

```csharp
IntPtr h = CreateFile(@"\\.\IBMPmDrv", 0x80000000, 1, IntPtr.Zero, 3, 0, IntPtr.Zero);
DeviceIoControl(h, 2238080, inp, 4, outp, 4, out ret, ref ov); // GET
DeviceIoControl(h, 2238084, inp, 4, outp, 4, out ret, ref ov); // SET
CloseHandle(h);
```

---

## Key Facts

- `IBMPMSVC` (Lenovo PM Service) must be running — it is by default on all ThinkPads
- The `State.Ex_31` registry key under `HKLM\SOFTWARE\Lenovo\HIDHotkey\` tracks backlight state but is written by `tphkload`, not read as a control input
- `tphkload` modules confirmed: `TPHKLOAD.exe`, `TPOSD.DLL`, `SHTCTKY.DLL`, `mmstate.dll`, `smm10.dll`, `spkvol.dll`
- ACPI device path: `\_SB.PC00.LPCB.EC.LHKF` (under Embedded Controller `ACPI\PNP0C09`)
- `shtctky.exe` references COM GUIDs `{56E4AAEA-4695-4DBC-A87F-0D666B421314}` and `{10FFBC57-CA53-4D1E-9E49-60AD847F0299}` — not registered in HKCR, in-process only

---

## Operational Hardening Notes

- On this Windows 11 ThinkPad, wake events are primarily logged as `Microsoft-Windows-Kernel-Power` Event ID `507` (Modern Standby exit) plus session unlock activity, not `Microsoft-Windows-Power-Troubleshooter` Event ID `1`. A task that only watches Power-Troubleshooter can appear correctly installed but still miss every real wake event.
- Some user contexts can read the existing scheduled task but cannot modify or replace it: both `schtasks /delete` and `schtasks /create` return `Access is denied`. The practical mitigation is to keep `C:\ProgramData\keyboard_backlight.ps1` as a stable bootstrap path, then update the file it points to instead of assuming the task itself can always be rewritten.
- A lightweight per-user monitor launched at logon is a pragmatic compatibility layer for Modern Standby systems. It can listen for resume and unlock events in the interactive session and re-run `kblight.exe 2` with retry logic even when the scheduled task trigger set is frozen.

---

## HP EliteBook / Poly Studio Path (Documented Interfaces)

### What was already documented

HP Client Management Script Library (CMSL) documents BIOS settings automation with:

- `Get-HPBIOSSettingsList`
- `Set-HPBIOSSettingValue`

References consulted:

- https://developers.hp.com/hp-client-management/doc/client-management-script-library
- https://developers.hp.com/hp-client-management/doc/bios-and-device

### Design decision

Unlike ThinkPad `IBMPmDrv`, no equivalent public HP kernel-level keyboard backlight runtime IOCTL path was identified in this workstream. To avoid undocumented or brittle behavior, HP support in this repository uses:

1. HP CMSL BIOS setting writes (preferred).
2. HP Instrumented BIOS WMI fallback (`root\HP\InstrumentedBIOS`) when CMSL cmdlets are unavailable.

### Practical implication

- ThinkPad path can force immediate level changes (`0/1/2`).
- HP path is best-effort persistence automation (timeout/enable-style BIOS setting control), which depends on model firmware capabilities and BIOS policy/password state.

### Validation signals for HP

`keyboard_backlight.log` should include one of:

- `success via hp-cmsl`
- `success via hp-wmi-fallback`

Failures usually indicate one of:

- HP CMSL module not present
- No keyboard backlight setting exposed by that firmware
- BIOS setup password/policy blocks write operations
