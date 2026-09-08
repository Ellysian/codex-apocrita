using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using ApocritaAdapter;

// A local-only harness: the only executable it can launch is its adjacent
// synthetic StreamFixture.exe. It cannot invoke WSL, SSH or arbitrary commands.
public static class NativeHarness
{
    static bool Mode(string[] args)
    {
        if (args.Length < 2) return false;
        switch (args[1]) {
            case "argv": return true;
            case "echo": return args.Length == 2 || (args.Length == 3 && args[2] == "23");
            case "wait": case "tree": case "duplex": return args.Length == 2;
            default: return false;
        }
    }
    public static int Main(string[] args)
    {
        string directory = Path.GetDirectoryName(Process.GetCurrentProcess().MainModule.FileName);
        string fixture = Path.Combine(directory, "StreamFixture.exe");
        if (args.Length == 0 || !Path.IsPathRooted(args[0]) ||
            !String.Equals(Path.GetFullPath(args[0]), fixture, StringComparison.OrdinalIgnoreCase) || !Mode(args)) {
            Console.Error.WriteLine("CONSTRAINED_HARNESS_REFUSED"); return 64;
        }
        return NativeProcess.Run(fixture, args.Skip(1).ToArray(), 0, false, null);
    }
}
