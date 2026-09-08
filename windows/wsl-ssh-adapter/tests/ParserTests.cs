using System;
using System.Collections.Generic;
using ApocritaAdapter;

public static class ParserTests
{
    private static int tests;
    private static ParsedSsh Parse(string[] args) { return SshArguments.Parse(args, Settings); }
    private static readonly AdapterSettings Settings = new AdapterSettings
    {
        Distribution = "Ubuntu", User = "researcher", LinuxHome = "/home/researcher",
        TargetAlias = "apocrita-codex", TargetHost = "login.example.invalid", TargetUser = "hpcuser", TargetPort = 22,
        LinuxSsh = "/usr/bin/ssh",
        LinuxConfig = "/home/researcher/.ssh/config", ControlPath = "/home/researcher/.ssh/ca-%C",
        WindowsSsh = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "OpenSSH", "ssh.exe"),
        WindowsConfigPath = @"C:\Users\Example\.ssh\config",
        WindowsIdentityPath = @"C:\Users\Example\.ssh\id_ed25519"
    };

    public static int Main()
    {
        try
        {
            CheckRouting();
            CheckOptionBoundaries();
            CheckArgumentPreservation();
            CheckTransforms();
            CheckRejections();
            CheckNoArgumentDisclosure();
            CheckConfigurableEndpoints();
            CheckInvalidSettings();
            Console.WriteLine("PASS: " + tests + " parser assertions; no network or HPC calls.");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine("FAIL: " + exception.Message);
            return 1;
        }
    }

    private static void CheckRouting()
    {
        Target(new[] { "apocrita-codex" }, true);
        Target(new[] { "APOCRITA-CODEX" }, true);
        Target(new[] { "hpcuser@login.example.invalid" }, true);
        Target(new[] { "-l", "hpcuser", "-p22", "login.example.invalid" }, true);
        Target(new[] { "-oUser=hpcuser", "-o", "Port 22", "login.example.invalid" }, true);
        Target(new[] { "ssh://hpcuser@login.example.invalid:22" }, true);
        Target(new[] { "login.example.invalid" }, false);
        Target(new[] { "someone@login.example.invalid" }, false);
        Target(new[] { "-p", "2222", "hpcuser@login.example.invalid" }, false);
        Target(new[] { "apocrita" }, false);
        Target(new[] { "-oHostName=login.example.invalid", "-lhpcuser", "apocrita" }, false);
        Target(new[] { "VS-example" }, false);
        Target(new[] { "hpcuser@not-login.example.invalid" }, false);
        Target(new[] { "hpcuser@login.example.invalid.evil.example" }, false);
        ParsedSsh version = Parse(new[] { "-V" });
        Assert(version.IsVersion && !version.IsTarget && version.Operation == "version", "version fallback");
        ParsedSsh query = Parse(new[] { "-Q", "help" });
        Assert(!query.IsTarget && query.Operation == "query", "query fallback");
        ParsedSsh fallback = Parse(new[] { "-J", "jump.example", "-L8080:localhost:80", "other-host", "cmd", "argument" });
        Assert(!fallback.IsTarget, "forwarding preserved for unrelated host");
        Sequence(fallback.RawArgs, new[] { "-J", "jump.example", "-L8080:localhost:80", "other-host", "cmd", "argument" }, "fallback args unchanged");
    }

    private static void CheckOptionBoundaries()
    {
        ParsedSsh combined = Parse(new[] { "-vvTnG", "-p22", "-lhpcuser", "-oBatchMode=yes", "apocrita-codex" });
        Assert(combined.IsConfig && combined.IsTarget && combined.User == "hpcuser" && combined.Port == 22, "combined flags and attached values");
        ParsedSsh spaces = Parse(new[] { "-o", "  User = hpcuser  ", "-o", "Port=22", "apocrita-codex" });
        Assert(spaces.IsTarget, "config whitespace separator");
        ParsedSsh secondPass = Parse(new[] { "apocrita-codex", "-vT", "-oServerAliveInterval=15", "codex", "--help", "-p", "other" });
        Sequence(secondPass.RemoteArgs, new[] { "codex", "--help", "-p", "other" }, "post-host options then remote boundary");
        ParsedSsh terminated = Parse(new[] { "--", "apocrita-codex", "-p", "2222", "-oProxyCommand=payload" });
        Sequence(terminated.RemoteArgs, new[] { "-p", "2222", "-oProxyCommand=payload" }, "first terminator preserves remote leading options");
        ParsedSsh afterHost = Parse(new[] { "apocrita-codex", "--", "-p", "2222" });
        Sequence(afterHost.RemoteArgs, new[] { "-p", "2222" }, "post-host terminator preserves remote options");
        string[] arities = { "B", "b", "c", "D", "E", "e", "F", "I", "i", "J", "L", "m", "O", "P", "Q", "R", "S", "W", "w" };
        foreach (string option in arities)
        {
            ParsedSsh valueIsAlias = Parse(new[] { "-" + option, "apocrita-codex", "unrelated-host", "command" });
            Assert(!valueIsAlias.IsTarget && valueIsAlias.Target == "unrelated-host", "option arity " + option);
        }
        ParsedSsh commandLooksLikeOptions = Parse(new[] { "apocrita-codex", "cmd", "-O", "exit", "-o", "HostName=other" });
        Assert(commandLooksLikeOptions.Operation == "connect", "remote text is not interpreted as options");
        string[] normalized = SshArguments.BuildLinuxArguments(terminated, Settings);
        Assert(Array.IndexOf(normalized, "--") >= 0, "normalized output has explicit boundary");
        Sequence(TailAfterDestination(normalized), terminated.RemoteArgs, "remote leading switch unchanged after normalization");
    }

    private static void CheckArgumentPreservation()
    {
        // Escapes keep the source ASCII while retaining Unicode argument coverage.
        string[] remote = { "codex", "app-server", "proxy", "", "two words", "\u4E2D\u6587\u53C2\u6570", "a\"b", "'single'", "C:\\path\\", "\\\"", "line1\nline2", "line1\r\nline2", "$HOME;$(touch nope)&|<>`backtick`", "*?[abc]", "--flag=\u503C" };
        List<string> source = new List<string> { "-T", "-n", "apocrita-codex" };
        source.AddRange(remote);
        ParsedSsh parsed = Parse(source.ToArray());
        Sequence(parsed.RemoteArgs, remote, "all remote argument boundaries preserved");
        string[] linux = SshArguments.BuildLinuxArguments(parsed, Settings);
        Sequence(TailAfterDestination(linux), remote, "all remote arguments preserved in Linux output");
        string[] original = source.ToArray();
        ParsedSsh clone = Parse(original);
        original[0] = "changed";
        Assert(clone.RawArgs[0] == "-T", "raw arguments defensively cloned");
        string[] command = { "apocrita-codex", "nohup codex app-server --listen 'unix:///tmp/a b' >file 2>&1 &" };
        Sequence(TailAfterDestination(SshArguments.BuildLinuxArguments(Parse(command), Settings)), new[] { command[1] }, "desktop shell command retained as one argument");
    }

    private static void CheckTransforms()
    {
        ParsedSsh parsed = Parse(new[] { "-G", "-F", Settings.WindowsConfigPath, "-i", Settings.WindowsIdentityPath,
            "-oControlPath=none", "-oControlMaster=auto", "-S", "unused-windows-control", "-oBatchMode=no", "-oConnectTimeout=999",
            "-oNumberOfPasswordPrompts=5", "-oConnectionAttempts=99", "-oServerAliveInterval=15", "-o", "ServerAliveCountMax 3", "apocrita-codex" });
        string[] built = SshArguments.BuildLinuxArguments(parsed, Settings);
        Assert(parsed.Operation == "config", "config operation");
        Contains(built, "BatchMode=yes"); Contains(built, "NumberOfPasswordPrompts=0");
        Contains(built, "ConnectionAttempts=1"); Contains(built, "ConnectTimeout=10");
        Contains(built, "ControlMaster=no"); Contains(built, "ControlPath=" + Settings.ControlPath);
        Contains(built, "ProxyCommand=/bin/false"); Contains(built, "StrictHostKeyChecking=yes");
        Contains(built, "PermitLocalCommand=no"); Contains(built, "ClearAllForwardings=yes");
        Contains(built, "ForwardAgent=no"); Contains(built, "RequestTTY=no");
        Contains(built, Settings.LinuxConfig); Contains(built, "ServerAliveInterval=15");
        Assert(Array.IndexOf(built, "-i") < 0 && Array.IndexOf(built, Settings.WindowsIdentityPath) < 0, "Windows identity removed");
        Assert(Array.IndexOf(built, Settings.WindowsConfigPath) < 0, "Windows config replaced");
        Assert(Array.IndexOf(built, "ControlPath=none") < 0, "ControlPath none replaced");
        Assert(parsed.AuditConversions.Length >= 4, "explicit conversion audit");
        ParsedSsh identityOption = Parse(new[] { "-o", "IdentityFile=\"" + Settings.WindowsIdentityPath + "\"", "apocrita-codex" });
        Assert(SshArguments.BuildLinuxArguments(identityOption, Settings).Length > 0, "quoted known identity option");
        ParsedSsh check = Parse(new[] { "-Ocheck", "apocrita-codex" });
        Assert(check.Operation == "control-check", "master check classified");
        Contains(SshArguments.BuildLinuxArguments(check, Settings), "check");
        ParsedSsh postHost = Parse(new[] { "login.example.invalid", "-lhpcuser", "-p22", "squeue" });
        Assert(postHost.IsTarget, "post-host identity participates in route");
        string[] postBuild = SshArguments.BuildLinuxArguments(postHost, Settings);
        Sequence(TailAfterDestination(postBuild), new[] { "squeue" }, "post-host options do not become remote command");
        string[] cases = SshArguments.BuildLinuxArguments(Parse(new[] { "-F", Settings.WindowsConfigPath.ToUpperInvariant(), "apocrita-codex" }), Settings);
        Contains(cases, Settings.LinuxConfig);
    }

    private static void CheckRejections()
    {
        RejectParse(new string[0]);
        RejectParse(new[] { "-o" });
        RejectParse(new[] { "-F" });
        RejectParse(new[] { "-Z", "apocrita-codex" });
        RejectParse(new[] { "-oUnknown\nHostName=evil", "apocrita-codex" });
        RejectParse(new[] { "-p0", "apocrita-codex" });
        RejectParse(new[] { "-p65536", "apocrita-codex" });
        RejectParse(new[] { "-p-1", "apocrita-codex" });
        RejectParse(new[] { "-p2222", "apocrita-codex" });
        RejectParse(new[] { "-lother", "apocrita-codex" });
        RejectParse(new[] { "other@apocrita-codex" });
        RejectParse(new[] { "-lhpcuser", "other@apocrita-codex" });
        RejectParse(new[] { "-lhpcuser", "-lother", "login.example.invalid" });
        RejectParse(new[] { "-p22", "-p2222", "hpcuser@login.example.invalid" });
        RejectParse(new[] { "apocrita-codex", "-p2222", "cmd" });
        RejectParse(new[] { "apocrita-codex;payload" });
        RejectParse(new[] { "$(payload)@apocrita-codex" });
        RejectParse(new[] { "apocrita-codex\nHostName=evil" });
        RejectParse(new[] { "apocrita-codex", "cmd\0payload" });
        RejectParse(new[] { "" });
        RejectBuild(new[] { "-oHostName=other.example", "apocrita-codex" });
        RejectBuild(new[] { "-oStrictHostKeyChecking=no", "apocrita-codex" });
        RejectBuild(new[] { "-oStrictHostKeyChecking=accept-new", "apocrita-codex" });
        RejectBuild(new[] { "-oUserKnownHostsFile=/dev/null", "apocrita-codex" });
        RejectBuild(new[] { "-oProxyCommand=payload", "apocrita-codex" });
        RejectBuild(new[] { "-oLocalCommand=payload", "apocrita-codex" });
        RejectBuild(new[] { "-oRemoteCommand=payload", "apocrita-codex" });
        RejectBuild(new[] { "-oInclude=other", "apocrita-codex" });
        RejectBuild(new[] { "-oIgnoreUnknown=*", "apocrita-codex" });
        RejectBuild(new[] { "-oUnknownOption=value", "apocrita-codex" });
        RejectBuild(new[] { "-oServerAliveInterval=15 payload", "apocrita-codex" });
        RejectBuild(new[] { "-F", "C:\\unknown\\config", "apocrita-codex" });
        RejectBuild(new[] { "-F", "config", "apocrita-codex" });
        RejectBuild(new[] { "-i", "C:\\unknown\\key", "apocrita-codex" });
        RejectBuild(new[] { "-Oexit", "apocrita-codex" });
        RejectBuild(new[] { "-Ostop", "apocrita-codex" });
        RejectBuild(new[] { "-Oforward", "apocrita-codex" });
        RejectBuild(new[] { "-J", "jump", "apocrita-codex" });
        RejectBuild(new[] { "-L", "8080:localhost:80", "apocrita-codex" });
        RejectBuild(new[] { "-R", "8080:localhost:80", "apocrita-codex" });
        RejectBuild(new[] { "-D8080", "apocrita-codex" });
        RejectBuild(new[] { "-A", "apocrita-codex" });
        RejectBuild(new[] { "-X", "apocrita-codex" });
        RejectBuild(new[] { "-tt", "apocrita-codex" });
        RejectBuild(new[] { "-E", "log-file", "apocrita-codex" });
        RejectBuild(new[] { "-oForwardAgent=yes", "apocrita-codex" });
        RejectBuild(new[] { "-oLocalForward=8080 localhost:80", "apocrita-codex" });
        RejectBuild(new[] { "-oClearAllForwardings=no", "apocrita-codex" });
        RejectBuild(new[] { "apocrita" });
    }

    private static void CheckNoArgumentDisclosure()
    {
        string marker = "PRIVATE_TEST_MARKER_do_not_log";
        try
        {
            SshArguments.BuildLinuxArguments(Parse(new[] { "-oUnknownOption=" + marker, "apocrita-codex", marker }), Settings);
            throw new Exception("expected sanitized failure");
        }
        catch (ArgumentException exception)
        {
            Assert(exception.Message.IndexOf(marker, StringComparison.Ordinal) < 0, "exception omits untrusted argument contents");
        }
    }

    private static AdapterSettings NewSettings()
    {
        return new AdapterSettings {
            Distribution = "Debian", User = "local-user", LinuxHome = "/data/home/local-user",
            TargetAlias = "research-endpoint", TargetHost = "cluster.example.invalid", TargetUser = "remote-user", TargetPort = 2207,
            LinuxSsh = "/usr/bin/ssh", LinuxConfig = "/data/home/local-user/.ssh/config",
            ControlPath = "/data/home/local-user/.ssh/master-%C",
            WindowsSsh = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "OpenSSH", "ssh.exe"),
            WindowsConfigPath = @"C:\Users\Example\.ssh\config", WindowsIdentityPath = null
        };
    }

    private static void CheckConfigurableEndpoints()
    {
        AdapterSettings settings = NewSettings();
        ParsedSsh alias = SshArguments.Parse(new[] { "research-endpoint", "codex", "app-server" }, settings);
        Assert(alias.IsTarget && alias.User == "remote-user" && alias.Port == 2207, "custom alias and non-default endpoint port");
        string[] linux = SshArguments.BuildLinuxArguments(alias, settings);
        Contains(linux, "HostName=cluster.example.invalid"); Contains(linux, "User=remote-user"); Contains(linux, "Port=2207");
        Contains(linux, "ControlPath=/data/home/local-user/.ssh/master-%C");
        Assert(settings.User != settings.TargetUser, "WSL and HPC identities remain separate");
        Assert(SshArguments.Parse(new[] { "ssh://remote-user@cluster.example.invalid:2207" }, settings).IsTarget, "custom explicit endpoint URI");
        Assert(!SshArguments.Parse(new[] { "apocrita-codex" }, settings).IsTarget, "old alias is unrelated after configuration change");
        Assert(!SshArguments.Parse(new[] { "remote-user@cluster.example.invalid" }, settings).IsTarget, "non-default explicit endpoint requires its port");
        Assert(!SshArguments.Parse(new[] { "ssh://other-user@cluster.example.invalid:2207" }, settings).IsTarget, "different remote identity stays on native route");
        try { SshArguments.Parse(new[] { "-p22", "research-endpoint" }, settings); throw new Exception("expected configured-port conflict"); }
        catch (ArgumentException) { tests++; }
        try { SshArguments.BuildLinuxArguments(SshArguments.Parse(new[] { "-i", @"C:\Users\Example\.ssh\key", "research-endpoint" }, settings), settings); throw new Exception("expected optional identity rejection"); }
        catch (ArgumentException) { tests++; }
        ParsedSsh check = SshArguments.Parse(new[] { "-O", "check", "research-endpoint" }, settings);
        string[] master = SshArguments.BuildLinuxArguments(check, settings);
        Contains(master, "BatchMode=yes"); Contains(master, "NumberOfPasswordPrompts=0");
        Contains(master, "ProxyCommand=/bin/false"); Contains(master, "ControlMaster=no");
        Contains(master, "Port=2207"); Contains(master, "check");
        string[] forced = SshArguments.BuildLinuxArguments(SshArguments.Parse(new[] { "-oBatchMode=no", "-oControlPath=wrong", "research-endpoint" }, settings), settings);
        Assert(Array.IndexOf(forced, "BatchMode=no") < 0 && Array.IndexOf(forced, "ControlPath=wrong") < 0, "fresh authentication cannot override first-value-wins guards");
        settings.Distribution = "Example Linux";
        SshArguments.ValidateSettings(settings); tests++;
    }

    private static void BadSettings(Action<AdapterSettings> change)
    {
        AdapterSettings settings = NewSettings(); change(settings);
        try { SshArguments.ValidateSettings(settings); }
        catch (ArgumentException) { tests++; return; }
        throw new Exception("expected invalid configuration rejection");
    }

    private static void CheckInvalidSettings()
    {
        BadSettings(s => s.Distribution = "Ubuntu\nPRIVATE_TEST_MARKER");
        BadSettings(s => s.User = "-root"); BadSettings(s => s.TargetUser = "user name");
        BadSettings(s => s.TargetAlias = "--help"); BadSettings(s => s.TargetAlias = "other;command");
        BadSettings(s => s.TargetHost = "login.example.invalid\nProxyCommand=payload");
        BadSettings(s => s.TargetHost = "$(payload)"); BadSettings(s => s.TargetHost = "host..invalid");
        BadSettings(s => s.TargetPort = 0); BadSettings(s => s.TargetPort = 65536);
        BadSettings(s => s.LinuxHome = "/"); BadSettings(s => s.LinuxHome = "/data/home/local-user/");
        BadSettings(s => s.LinuxHome = "/data/home/../other");
        BadSettings(s => s.LinuxSsh = "ssh"); BadSettings(s => s.LinuxSsh = "/usr/bin/ssh -v");
        BadSettings(s => s.LinuxSsh = "/tmp/ssh");
        BadSettings(s => s.LinuxConfig = "/tmp/config");
        BadSettings(s => s.ControlPath = "/data/home/local-user/.ssh/../outside");
        BadSettings(s => s.ControlPath = "/data/home/local-user-other/.ssh/master-%C");
        BadSettings(s => s.ControlPath = "/data/home/local-user/.ssh/master-%h");
        BadSettings(s => s.ControlPath = "/data/home/local-user/.ssh/master-${HOME}");
        BadSettings(s => s.ControlPath = "/data/home/local-user/.ssh//master");
        BadSettings(s => s.WindowsSsh = @"C:ssh.exe");
        BadSettings(s => s.WindowsSsh = @"\\server\share\ssh.exe");
        BadSettings(s => s.WindowsSsh = @"C:\Windows\System32\cmd.exe");
        BadSettings(s => s.WindowsSsh = @"C:\Users\Example\bin\ssh.exe");
        BadSettings(s => s.WindowsConfigPath = @"C:\Users\Example\config:alternate");
        BadSettings(s => s.WindowsConfigPath = @"%USERPROFILE%\.ssh\config");
        BadSettings(s => s.WindowsIdentityPath = "");
    }

    private static string[] TailAfterDestination(string[] args)
    {
        int start = Array.IndexOf(args, "--") + 2;
        Assert(start >= 2 && start <= args.Length, "destination boundary exists");
        string[] result = new string[args.Length - start];
        Array.Copy(args, start, result, 0, result.Length);
        return result;
    }

    private static void Target(string[] args, bool expected)
    {
        Assert(Parse(args).IsTarget == expected, "target routing");
    }

    private static void RejectParse(string[] args)
    {
        try { Parse(args); }
        catch (ArgumentException) { tests++; return; }
        throw new Exception("expected parser rejection");
    }

    private static void RejectBuild(string[] args)
    {
        try { SshArguments.BuildLinuxArguments(Parse(args), Settings); }
        catch (ArgumentException) { tests++; return; }
        throw new Exception("expected target-policy rejection");
    }

    private static void Contains(string[] args, string expected)
    {
        Assert(Array.IndexOf(args, expected) >= 0, "required policy argument");
    }

    private static void Sequence(string[] actual, string[] expected, string reason)
    {
        Assert(actual.Length == expected.Length, reason + " length");
        for (int i = 0; i < actual.Length; i++) Assert(actual[i] == expected[i], reason + " item " + i);
    }

    private static void Assert(bool condition, string reason)
    {
        tests++;
        if (!condition) throw new Exception(reason);
    }
}
