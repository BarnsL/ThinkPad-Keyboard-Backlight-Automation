# OPERATIONS.md

Runtime notes and validation checklist for deployed keyboard backlight automation on ThinkPad and HP EliteBook systems.

---

## Runtime Layout

Canonical payload directory:

```text
C:\ProgramData\KbBacklight\
  keyboard_backlight.ps1
  hp_keyboard_backlight.ps1
  kblight.exe
  keyboard_backlight.log
```

Stable bootstrap path:

```text
C:\ProgramData\keyboard_backlight.ps1
```

The bootstrap points to the active platform script selected at install time.

---

## Installer Process

`install.ps1` performs:

1. Platform selection (`Auto`, `ThinkPad`, `HpEliteBook`).
2. Payload copy to `C:\ProgramData\KbBacklight\`.
3. ThinkPad-only compile of `kblight.exe` when needed.
4. Bootstrap rewrite at `C:\ProgramData\keyboard_backlight.ps1`.
5. Task registration for:
   - Logon
   - Session unlock
   - Power-Troubleshooter Event ID 1
   - Kernel-Power Event ID 507
6. HKCU Run fallback when task replacement is blocked.

Run fallback entries:

```text
HKCU\Software\Microsoft\Windows\CurrentVersion\Run
  ThinkPad Keyboard Backlight
  HP EliteBook Keyboard Backlight
```

---

## Validation Checklist

### Common checks

Tail runtime logs:

```powershell
Get-Content C:\ProgramData\KbBacklight\keyboard_backlight.log -Tail 80
```

Inspect scheduler actions:

```powershell
Get-ScheduledTask -TaskName "ThinkPad Keyboard Backlight" -ErrorAction SilentlyContinue |
  Select-Object TaskName, State, @{N='Arguments';E={$_.Actions.Arguments}}

Get-ScheduledTask -TaskName "HP EliteBook Keyboard Backlight" -ErrorAction SilentlyContinue |
  Select-Object TaskName, State, @{N='Arguments';E={$_.Actions.Arguments}}
```

### ThinkPad validation

Driver check:

```powershell
C:\ProgramData\KbBacklight\kblight.exe status
```

Bootstrap run:

```powershell
& 'C:\ProgramData\KbBacklight\keyboard_backlight.ps1' -EnsureMonitor
```

Expected indicators:

- `success attempt=... exitCode=0`
- `monitor bootstrap launched` and `monitor started pid=...`
- `detected off reason=... target=1 raw=...` when remediation fires

### HP EliteBook validation

CMSL surface check:

```powershell
Get-Command Get-HPBIOSSettingsList, Set-HPBIOSSettingValue
```

HP runtime run:

```powershell
& 'C:\ProgramData\KbBacklight\hp_keyboard_backlight.ps1' -EnsureMonitor
```

Expected indicators:

- `success via hp-cmsl`
- or `success via hp-wmi-fallback`

If BIOS setup password policy blocks writes, log output should show failed setting apply attempts.

---

## Test Process Used For This Update

The update process for HP support was documented and validated in this order:

1. Confirmed no prior HP-specific implementation existed in repository scripts/docs.
2. Verified HP documented automation path in HP CMSL docs (`Get-HPBIOSSettingsList`, `Set-HPBIOSSettingValue`).
3. Added a dedicated HP runtime script that only uses documented interfaces.
4. Added installer auto-detection and explicit platform override switches.
5. Added HP task names and uninstall cleanup.
6. Added process-oriented validation steps for both platform paths.

---

## Removal

`uninstall.ps1` removes:

- `C:\ProgramData\KbBacklight\`
- `C:\ProgramData\keyboard_backlight.ps1`
- ThinkPad and HP scheduled task variants
- ThinkPad and HP HKCU Run fallback values
