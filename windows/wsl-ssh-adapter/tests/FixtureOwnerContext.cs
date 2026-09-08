using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace ApocritaAdapter.Tests
{
    // Hosted Windows runners can default new object ownership to Administrators.
    // Use the same effective identity and privileges, with a private impersonation
    // token whose default owner is its user SID. Never modify the process token.
    public static class FixtureOwnerContext
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct TokenOwner { public IntPtr Owner; }

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DuplicateTokenEx(
            SafeAccessTokenHandle existingToken, uint desiredAccess,
            IntPtr tokenAttributes, int impersonationLevel, int tokenType,
            out SafeAccessTokenHandle newToken);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetTokenInformation(
            SafeAccessTokenHandle token, int informationClass,
            ref TokenOwner information, int informationLength);

        public static object Run(Func<object> fixture)
        {
            if (fixture == null) throw new ArgumentNullException("fixture");
            using (WindowsIdentity original = WindowsIdentity.GetCurrent())
            {
                SafeAccessTokenHandle duplicate;
                // TOKEN_IMPERSONATE | TOKEN_QUERY | TOKEN_ADJUST_DEFAULT.
                // These are handle access rights; no token privileges are added.
                if (!DuplicateTokenEx(original.AccessToken, 0x008c, IntPtr.Zero,
                    2 /* SecurityImpersonation */, 2 /* TokenImpersonation */,
                    out duplicate))
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "Could not create the fixture ownership context.");
                using (duplicate)
                {
                    byte[] sid = new byte[original.User.BinaryLength];
                    original.User.GetBinaryForm(sid, 0);
                    IntPtr sidMemory = Marshal.AllocHGlobal(sid.Length);
                    try
                    {
                        Marshal.Copy(sid, 0, sidMemory, sid.Length);
                        TokenOwner owner = new TokenOwner { Owner = sidMemory };
                        if (!SetTokenInformation(duplicate, 4 /* TokenOwner */,
                            ref owner, Marshal.SizeOf(typeof(TokenOwner))))
                            throw new Win32Exception(Marshal.GetLastWin32Error(),
                                "Could not set the fixture default owner.");
                    }
                    finally { Marshal.FreeHGlobal(sidMemory); }

                    // RunImpersonated restores the previous thread context even
                    // when the fixture throws. The duplicate is then disposed.
                    return WindowsIdentity.RunImpersonated(duplicate, delegate
                    {
                        using (WindowsIdentity effective = WindowsIdentity.GetCurrent())
                        {
                            if (!effective.User.Equals(original.User))
                                throw new InvalidOperationException(
                                    "Fixture ownership context changed the user identity.");
                        }
                        return fixture();
                    });
                }
            }
        }
    }
}
