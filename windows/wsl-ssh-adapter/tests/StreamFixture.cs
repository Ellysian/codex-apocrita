using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;
using System.Runtime.InteropServices;
public static class StreamFixture
{
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
    static Stream Std(int n, FileAccess access) { return new FileStream(new SafeFileHandle(GetStdHandle(n),false), access,8192,false); }
    static void Text(int n,string text) { byte[] b=new UTF8Encoding(false).GetBytes(text); var s=Std(n,FileAccess.Write); s.Write(b,0,b.Length); s.Flush(); }
    public static int Main(string[] args) {
        if(args.Length == 0) return 64;
        if(args[0] == "argv") {
            var encoded = new StringBuilder("ARGV64 " + (args.Length - 1) + "\n");
            foreach(string value in args.Skip(1)) encoded.Append(Convert.ToBase64String(Encoding.UTF8.GetBytes(value))).Append('\n');
            Text(-11,encoded.ToString()); return 0;
        }
        if(args[0] == "echo" || args[0] == "duplex") {
            if(args[0] == "duplex") Text(-11,"PID " + Process.GetCurrentProcess().Id + "\n");
            byte[] data = new byte[8192]; int n; var input = Std(-10,FileAccess.Read); var output = Std(-11,FileAccess.Write);
            Text(-12,"STDERR_ONLY\n");
            while((n = input.Read(data, 0, data.Length)) > 0) { output.Write(data,0,n); output.Flush(); }
            return args[0] == "echo" && args.Length > 1 ? Int32.Parse(args[1]) : 0;
        }
        if(args[0] == "wait") { Text(-11,"PID " + Process.GetCurrentProcess().Id+"\n"); Thread.Sleep(45000); return 0; }
        if(args[0] == "tree") {
            var p = Process.Start(new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName, "wait") { UseShellExecute=false, CreateNoWindow=true, RedirectStandardOutput=true, RedirectStandardError=true });
            Text(-11,"TREE " + Process.GetCurrentProcess().Id+" " + p.Id+"\n");
            p.WaitForExit(); return p.ExitCode;
        }
        return 64;
    }
}
