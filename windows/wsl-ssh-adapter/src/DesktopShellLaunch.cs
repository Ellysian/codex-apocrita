using System;
using System.Text;
using System.Runtime.InteropServices;

namespace Apocrita.ProfileGuard
{
    // Read-only public Windows API used by the short-lived profile lease guard.
    // Desktop launch itself uses IApplicationActivationManager in the other file.
    public static class PackageIdentity
    {
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
        static extern int GetPackageFullName(IntPtr process, ref uint length, StringBuilder name);
        public static string Read(uint pid)
        {
            IntPtr process = OpenProcess(0x1000, false, pid);
            if (process == IntPtr.Zero) return null;
            try
            {
                uint length = 0;
                if (GetPackageFullName(process, ref length, null) != 122 || length == 0 || length > 1024) return null;
                var name = new StringBuilder((int)length);
                return GetPackageFullName(process, ref length, name) == 0 ? name.ToString() : null;
            }
            finally { CloseHandle(process); }
        }
    }
}
