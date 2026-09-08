using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace ApocritaAdapter
{
    // Inherit byte handles directly; do not decode or buffer the SSH protocol.
    public static class NativeProcess
    {
        const uint DUPLICATE_SAME_ACCESS = 2, STARTF_USESTDHANDLES = 0x100;
        const uint CREATE_SUSPENDED = 4, CREATE_NO_WINDOW = 0x08000000;
        const uint WAIT_OBJECT_0 = 0, WAIT_TIMEOUT = 258;
        static readonly IntPtr Invalid = new IntPtr(-1);
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct STARTUPINFO { public uint cb; public string lpReserved, lpDesktop, lpTitle;
            public uint dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
            public ushort wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError; }
        [StructLayout(LayoutKind.Sequential)]
        struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public uint dwProcessId, dwThreadId; }
        [StructLayout(LayoutKind.Sequential)]
        struct BASIC_LIMIT { public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize; public uint ActiveProcessLimit;
            public UIntPtr Affinity; public uint PriorityClass, SchedulingClass; }
        [StructLayout(LayoutKind.Sequential)]
        struct IO_COUNTERS { public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount,
            ReadTransferCount, WriteTransferCount, OtherTransferCount; }
        [StructLayout(LayoutKind.Sequential)]
        struct EXTENDED_LIMIT { public BASIC_LIMIT BasicLimitInformation; public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }
        [StructLayout(LayoutKind.Sequential)]
        struct SECURITY_ATTRIBUTES { public uint nLength; public IntPtr lpSecurityDescriptor; public int bInheritHandle; }
        delegate bool Handler(uint type);
        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        static extern bool CreateProcess(string app, StringBuilder command, IntPtr pa, IntPtr ta, bool inherit,
            uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
        [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr a, string n);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int type, ref EXTENDED_LIMIT info, uint size);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job, uint code);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(IntPtr process, uint code);
        [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool DuplicateHandle(IntPtr sp, IntPtr sh, IntPtr tp, out IntPtr th, uint access, bool inherit, uint options);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetConsoleCtrlHandler(Handler h, bool add);
        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        static extern IntPtr CreateFile(string name, uint access, uint share, ref SECURITY_ATTRIBUTES sa, uint create, uint flags, IntPtr template);

        public static string Quote(string argument)
        {
            if (argument == null || argument.IndexOf('\0') >= 0) throw new ArgumentException("Invalid process argument.");
            // WSL parses its option prefix from the raw command line. Quoting
            // even a plain --distribution changes it into a Linux command.
            if (argument.Length > 0 && argument.IndexOfAny(new [] {' ', '\t', '\r', '\n', '\v', '"'}) < 0) return argument;
            var s = new StringBuilder("\""); int slashes = 0;
            foreach (char c in argument) {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') { s.Append('\\', slashes * 2 + 1); s.Append('"'); }
                else { s.Append('\\', slashes); s.Append(c); }
                slashes = 0;
            }
            s.Append('\\', slashes * 2); s.Append('"'); return s.ToString();
        }
        static IntPtr Standard(int kind, bool quiet)
        {
            IntPtr raw = quiet ? IntPtr.Zero : GetStdHandle(kind), copy;
            if (raw != IntPtr.Zero && raw != Invalid) {
                if (!DuplicateHandle(GetCurrentProcess(), raw, GetCurrentProcess(), out copy, 0, true, DUPLICATE_SAME_ACCESS))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot inherit standard stream.");
                return copy;
            }
            var sa = new SECURITY_ATTRIBUTES { nLength = (uint)Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)), bInheritHandle = 1 };
            copy = CreateFile("NUL", kind == -10 ? 0x80000000u : 0x40000000u, 3, ref sa, 3, 0, IntPtr.Zero);
            if (copy == Invalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            return copy;
        }
        public static int Run(string executable, string[] arguments, int timeoutMilliseconds, bool quiet, Action<int> started)
        {
            if (!System.IO.Path.IsPathRooted(executable)) throw new ArgumentException("Executable must be absolute.");
            IntPtr job = IntPtr.Zero; var inherited = new List<IntPtr>(); var pi = new PROCESS_INFORMATION();
            bool created = false, assigned = false, done = false, cancelled = false;
            Handler handler = delegate(uint t) {
                if (t == 0 || t == 1 || t == 2 || t == 5 || t == 6) {
                    cancelled = true; if (job != IntPtr.Zero) TerminateJobObject(job, 130); return true;
                }
                return false;
            };
            try {
                job = CreateJobObject(IntPtr.Zero, null);
                if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                var limits = new EXTENDED_LIMIT(); limits.BasicLimitInformation.LimitFlags = 0x2000; // KILL_ON_JOB_CLOSE
                if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(EXTENDED_LIMIT))))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot configure child cleanup.");
                var si = new STARTUPINFO { cb = (uint)Marshal.SizeOf(typeof(STARTUPINFO)), dwFlags = STARTF_USESTDHANDLES };
                si.hStdInput = Standard(-10, quiet); inherited.Add(si.hStdInput);
                si.hStdOutput = Standard(-11, quiet); inherited.Add(si.hStdOutput);
                si.hStdError = Standard(-12, quiet); inherited.Add(si.hStdError);
                var cmd = new StringBuilder(Quote(executable));
                foreach (string arg in arguments) cmd.Append(' ').Append(Quote(arg));
                if (!CreateProcess(executable, cmd, IntPtr.Zero, IntPtr.Zero, true,
                    CREATE_SUSPENDED | CREATE_NO_WINDOW, IntPtr.Zero, Environment.CurrentDirectory, ref si, out pi))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot launch configured SSH transport.");
                created = true;
                if (!AssignProcessToJobObject(job, pi.hProcess))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot guarantee child process cleanup.");
                assigned = true;
                SetConsoleCtrlHandler(handler, true);
                foreach (IntPtr h in inherited) CloseHandle(h); inherited.Clear();
                if (started != null) started((int)pi.dwProcessId);
                if (ResumeThread(pi.hThread) == uint.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error());
                uint wait = WaitForSingleObject(pi.hProcess, timeoutMilliseconds > 0 ? (uint)timeoutMilliseconds : uint.MaxValue);
                if (wait == WAIT_TIMEOUT) { TerminateJobObject(job, 124); WaitForSingleObject(pi.hProcess, 5000); done = true; return 124; }
                if (wait != WAIT_OBJECT_0) throw new Win32Exception(Marshal.GetLastWin32Error());
                uint code; if (!GetExitCodeProcess(pi.hProcess, out code)) throw new Win32Exception(Marshal.GetLastWin32Error());
                done = true; return cancelled ? 130 : unchecked((int)code);
            }
            finally {
                SetConsoleCtrlHandler(handler, false); GC.KeepAlive(handler);
                if (created && !done) { if (assigned) TerminateJobObject(job, 125); else TerminateProcess(pi.hProcess, 125); }
                if (pi.hThread != IntPtr.Zero) CloseHandle(pi.hThread);
                if (pi.hProcess != IntPtr.Zero) CloseHandle(pi.hProcess);
                foreach (IntPtr h in inherited) CloseHandle(h);
                if (job != IntPtr.Zero) CloseHandle(job);
            }
        }
    }
}
