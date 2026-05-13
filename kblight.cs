/*
 * kblight.cs - ThinkPad Keyboard Backlight Control
 *
 * Controls the keyboard backlight on ThinkPad laptops by sending
 * DeviceIoControl calls to the IBM Power Management driver (IBMPmDrv).
 *
 * Usage:
 *   kblight.exe <level>
 *   level: 0 = off, 1 = low, 2 = high
 *
 * How it works:
 *   The Lenovo/IBM Power Management driver exposes a device at \\.\IBMPmDrv.
 *   Two IOCTL codes control the keyboard backlight:
 *     - 2238080 (GET): reads current backlight state and capabilities
 *     - 2238084 (SET): sets the backlight level
 *
 *   The GET response is a packed 32-bit integer:
 *     bits  3:0  = current level (0/1/2)
 *     bits 11:8  = max level (typically 2)
 *     bits 19:16 = 0x5 when backlight hardware is present and ready
 *     bit  21    = flag that must be preserved in SET arg (0x100 offset)
 *
 *   The SET argument is constructed as:
 *     arg = (bit21_flag ? 0x100 : 0) | (GET_result & 0xF0) | desired_level
 *
 * Credit:
 *   Control method discovered by pspatel321/auto-backlight-for-thinkpad
 *   https://github.com/pspatel321/auto-backlight-for-thinkpad
 *
 * Compile:
 *   C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /out:kblight.exe kblight.cs
 */

using System;
using System.Runtime.InteropServices;
using System.Threading;

class KbLight {
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool DeviceIoControl(IntPtr h, uint code, byte[] inBuf, uint inSize, byte[] outBuf, uint outSize, out uint returned, ref NativeOverlapped ov);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CloseHandle(IntPtr h);

    const uint IOCTL_GET = 2238080; // Read backlight state + capabilities
    const uint IOCTL_SET = 2238084; // Write backlight level

    // Send a DeviceIoControl call to the IBM PM driver
    static int CallPm(uint code, int input) {
        IntPtr h = CreateFile(@"\\.\IBMPmDrv", 0x80000000, 1, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (h == IntPtr.Zero || h.ToInt64() == -1)
            throw new Exception("Cannot open IBMPmDrv (error " + Marshal.GetLastWin32Error() + ") - is IBMPMSVC running?");
        byte[] inp = BitConverter.GetBytes(input);
        byte[] outp = new byte[4];
        uint ret = 0;
        NativeOverlapped ov = new NativeOverlapped();
        bool ok = DeviceIoControl(h, code, inp, (uint)inp.Length, outp, (uint)outp.Length, out ret, ref ov);
        CloseHandle(h);
        if (!ok) throw new Exception("DeviceIoControl failed (error " + Marshal.GetLastWin32Error() + ")");
        return BitConverter.ToInt32(outp, 0);
    }

    static void Main(string[] args) {
        if (args.Length == 0 || args[0] == "--help" || args[0] == "-h") {
            Console.WriteLine("kblight.exe <level>");
            Console.WriteLine("  0 = off, 1 = low, 2 = high");
            return;
        }

        int level = int.Parse(args[0]);
        if (level < 0 || level > 2) {
            Console.WriteLine("Level must be 0, 1, or 2");
            Environment.Exit(1);
        }

        try {
            // GET: read current state and verify hardware is present
            int code = CallPm(IOCTL_GET, 0);
            if ((code & 0x0050000) != 0x0050000) {
                Console.WriteLine("Backlight hardware not ready (GET=0x" + code.ToString("X") + ")");
                Environment.Exit(1);
            }

            int currentLevel = code & 0xF;
            int maxLevel = (code >> 8) & 0xF;

            // SET: construct argument preserving required flags from GET response
            int arg = ((code & 0x00200000) != 0 ? 0x100 : 0) | (code & 0xF0) | level;
            int result = CallPm(IOCTL_SET, arg);

            Console.WriteLine("OK level=" + level + " (was " + currentLevel + ", max=" + maxLevel + ")");
            Environment.Exit(result); // 0 = success
        } catch (Exception ex) {
            Console.WriteLine("Error: " + ex.Message);
            Environment.Exit(1);
        }
    }
}
