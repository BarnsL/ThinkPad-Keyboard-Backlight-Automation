# RESEARCH.md — ThinkPad Keyboard Backlight Automation

Full notes on every approach tried to automate the ThinkPad keyboard backlight on Windows, what failed, and what ultimately worked.

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
