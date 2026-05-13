# keyboard_backlight.ps1
#
# Sets the ThinkPad keyboard backlight to ON (level 2) at logon and resume from sleep.
# Registered as a scheduled task by install.ps1.
#
# Mechanism:
#   Uses DeviceIoControl on \\.\IBMPmDrv (IBM Power Management driver).
#   IOCTL 2238080 = GET current state, IOCTL 2238084 = SET level.
#   No elevation required. No external dependencies.
#
# Credit:
#   Control method discovered by pspatel321/auto-backlight-for-thinkpad

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Threading;

public class KbBacklight {
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool DeviceIoControl(IntPtr h, uint code, byte[] inBuf, uint inSize, byte[] outBuf, uint outSize, out uint returned, ref NativeOverlapped ov);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CloseHandle(IntPtr h);

    const uint IOCTL_GET = 2238080;
    const uint IOCTL_SET = 2238084;

    static int CallPm(uint code, int input) {
        IntPtr h = CreateFile(@"\\.\IBMPmDrv", 0x80000000, 1, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (h == IntPtr.Zero || h.ToInt64() == -1)
            throw new Exception("Cannot open IBMPmDrv");
        byte[] inp = BitConverter.GetBytes(input);
        byte[] outp = new byte[4];
        uint ret = 0;
        NativeOverlapped ov = new NativeOverlapped();
        bool ok = DeviceIoControl(h, code, inp, (uint)inp.Length, outp, (uint)outp.Length, out ret, ref ov);
        CloseHandle(h);
        if (!ok) throw new Exception("DeviceIoControl failed");
        return BitConverter.ToInt32(outp, 0);
    }

    public static int SetLevel(int level) {
        int code = CallPm(IOCTL_GET, 0);
        if ((code & 0x0050000) != 0x0050000) throw new Exception("Backlight hw not ready");
        int arg = ((code & 0x00200000) != 0 ? 0x100 : 0) | (code & 0xF0) | level;
        return CallPm(IOCTL_SET, arg);
    }
}
"@

# Brief wait for drivers to be ready after resume from sleep
Start-Sleep -Seconds 3

# Try to set level 2 (high), fall back to level 1, retry once on failure
$attempts = 0
$success = $false
while ($attempts -lt 2 -and -not $success) {
    try {
        $r = [KbBacklight]::SetLevel(2)
        if ($r -eq 0) { $success = $true }
    } catch {
        Start-Sleep -Seconds 4
    }
    $attempts++
}
