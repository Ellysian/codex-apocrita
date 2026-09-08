using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;

namespace ApocritaAdapter
{
    // Configuration is supplied by the launcher; this class never reads files.
    public sealed class AdapterSettings
    {
        public string Distribution;
        public string User;
        public string LinuxHome;
        public string TargetAlias;
        public string TargetHost;
        public string TargetUser;
        public int TargetPort;
        public string LinuxSsh;
        public string ControlPath;
        public string WindowsConfigPath;
        public string WindowsIdentityPath;
        public string WindowsSsh;
        public string LinuxConfig;
        public bool MetadataLogging;
    }

    public sealed class ParsedSsh
    {
        public string Target;
        public string User;
        public int Port;
        public bool IsConfig;
        public bool IsVersion;
        public bool IsTarget;
        public string RouteTarget;
        public string Operation;
        public string[] RawArgs;
        public string[] RemoteArgs;
        public string[] AuditConversions = new string[0];
        internal string Host;
        internal List<SshOption> Options;
        internal List<string> UserValues;
        internal List<int> PortValues;
    }

    internal sealed class SshOption
    {
        internal char Name;
        internal string Value;
        internal string ConfigKey;
        internal string ConfigValue;
    }

    public static class SshArguments
    {
        // OpenSSH 9.6p1 ssh.c's getopt arities. A later, unknown switch fails
        // explicitly: guessing its arity could accidentally reinterpret a host.
        private const string NoArgument = "1246aCfGgKkMNnqsTtVvXxYyA";
        private const string WithArgument = "BbcDEeFIiJLlmOoPpQRSWw";

        public static ParsedSsh Parse(string[] args, AdapterSettings settings)
        {
            ValidateSettings(settings);
            if (args == null) throw Error("SSH arguments are missing.");
            string[] raw = (string[])args.Clone();
            foreach (string arg in raw)
                if (arg == null || arg.IndexOf('\0') >= 0)
                    throw Error("SSH argument contains an invalid character.");

            ParsedSsh result = new ParsedSsh();
            result.RawArgs = raw;
            result.Options = new List<SshOption>();
            result.UserValues = new List<string>();
            result.PortValues = new List<int>();
            result.Port = 22;
            int index = 0;
            bool terminated = ParseOptions(raw, ref index, result);
            if (index < raw.Length)
            {
                result.Target = raw[index++];
                ParseDestination(result);
                // Like OpenSSH, parse switches immediately after destination,
                // unless an earlier -- explicitly ended option processing.
                if (!terminated) ParseOptions(raw, ref index, result);
            }
            result.RemoteArgs = Slice(raw, index);

            string firstUser = result.UserValues.Count == 0 ? null : result.UserValues[0];
            result.User = firstUser;
            if (result.PortValues.Count != 0) result.Port = result.PortValues[0];
            bool alias = Equal(result.Host, settings.TargetAlias);
            bool explicitHost = Equal(result.Host, settings.TargetHost) && Equal(firstUser, settings.TargetUser)
                && result.Port == settings.TargetPort;
            result.IsTarget = !result.IsVersion && (alias || explicitHost);
            if (result.IsTarget)
            {
                foreach (string user in result.UserValues)
                    if (!String.Equals(user, settings.TargetUser, StringComparison.Ordinal))
                        throw Error("Conflicting user for the protected HPC target.");
                foreach (int port in result.PortValues)
                    if (port != settings.TargetPort) throw Error("Conflicting port for the protected HPC target.");
                result.User = settings.TargetUser;
                result.Port = settings.TargetPort;
            }
            result.RouteTarget = result.IsTarget ? settings.TargetAlias : result.Target;
            result.Operation = result.IsVersion ? "version" : result.IsConfig ? "config" : "connect";
            foreach (SshOption option in result.Options)
            {
                if (option.Name == 'O')
                    result.Operation = Equal(option.Value, "check") ? "control-check" : "control-other";
                if (option.Name == 'Q') result.Operation = "query";
            }
            if (result.Target == null && !result.IsVersion && result.Operation != "query")
                throw Error("SSH destination is missing.");
            return result;
        }

        // Pure argument transformation. No SSH execution, config parsing, IO,
        // secret handling, shell evaluation, or stdout writes occurs here.
        public static string[] BuildLinuxArguments(ParsedSsh parsed, AdapterSettings settings)
        {
            if (parsed == null) throw Error("Parsed SSH arguments are missing.");
            ParsedSsh input = Parse(parsed.RawArgs, settings);
            if (!input.IsTarget) throw Error("Only the protected HPC target may use WSL routing.");
            ValidateSettings(settings);
            List<string> output = new List<string>();
            List<string> audit = new List<string>();

            // Put first-value-wins -o policies before every caller option and
            // before configuration files. The false proxy is deliberate: if a
            // master disappears after precheck, no fresh network login occurs.
            AddConfig(output, "BatchMode=yes");
            AddConfig(output, "NumberOfPasswordPrompts=0");
            AddConfig(output, "ConnectionAttempts=1");
            AddConfig(output, "ConnectTimeout=10");
            AddConfig(output, "ControlMaster=no");
            AddConfig(output, "ControlPath=" + settings.ControlPath);
            AddConfig(output, "ProxyCommand=/bin/false");
            AddConfig(output, "StrictHostKeyChecking=yes");
            AddConfig(output, "HostName=" + settings.TargetHost);
            AddConfig(output, "User=" + settings.TargetUser);
            AddConfig(output, "Port=" + settings.TargetPort.ToString(CultureInfo.InvariantCulture));
            AddConfig(output, "CanonicalizeHostname=no");
            AddConfig(output, "PermitLocalCommand=no");
            AddConfig(output, "ClearAllForwardings=yes");
            AddConfig(output, "ForwardAgent=no");
            AddConfig(output, "ForwardX11=no");
            AddConfig(output, "RequestTTY=no");
            output.Add("-F");
            output.Add(settings.LinuxConfig);

            foreach (SshOption option in input.Options)
            {
                switch (option.Name)
                {
                    case 'o':
                        TransformConfig(option, settings, output, audit);
                        break;
                    case 'F':
                        if (!SameWindowsPath(option.Value, settings.WindowsConfigPath) &&
                            !String.Equals(option.Value, settings.LinuxConfig, StringComparison.Ordinal))
                            throw Error("Unrecognized SSH configuration path for the protected target.");
                        AddAudit(audit, "config-path-mapped-to-fixed-linux-config");
                        break;
                    case 'i':
                        ValidateIdentity(option.Value, settings);
                        AddAudit(audit, "windows-identity-removed-use-existing-linux-identity");
                        break;
                    case 'l':
                    case 'p':
                        // Parsed values have already been checked; fixed -o
                        // values above preserve the verified endpoint identity.
                        break;
                    case 'S':
                    case 'M':
                        AddAudit(audit, "control-options-replaced-with-fixed-existing-master");
                        break;
                    case 'O':
                        if (!String.Equals(option.Value, "check", StringComparison.Ordinal))
                            throw Error("Only a control-master status check is allowed.");
                        output.Add("-O"); output.Add("check");
                        break;
                    case 'G': case 'T': case 'n': case 'v': case 'q':
                    case '4': case '6': case '2': case 'a': case 'x':
                    case 'k': case 'C':
                        output.Add("-" + option.Name);
                        break;
                    case 'D': case 'L': case 'R': case 'W': case 'w':
                    case 'J': case 'A': case 'X': case 'Y': case 'g': case 'K':
                        throw Error("Forwarding is not supported for the protected HPC target.");
                    case 't':
                        throw Error("TTY allocation is not allowed for the adapter protocol.");
                    default:
                        throw Error("SSH option is not supported for the protected HPC target.");
                }
            }
            output.Add("--");
            output.Add(input.Target);
            output.AddRange(input.RemoteArgs);
            parsed.AuditConversions = audit.ToArray();
            return output.ToArray();
        }

        private static bool ParseOptions(string[] args, ref int index, ParsedSsh result)
        {
            while (index < args.Length)
            {
                string token = args[index];
                if (token == "--") { index++; return true; }
                if (token.Length < 2 || token[0] != '-') return false;
                index++;
                for (int offset = 1; offset < token.Length; offset++)
                {
                    char name = token[offset];
                    bool takesValue = WithArgument.IndexOf(name) >= 0;
                    if (!takesValue && NoArgument.IndexOf(name) < 0)
                        throw Error("Unknown SSH option; refusing ambiguous argument parsing.");
                    string value = null;
                    if (takesValue)
                    {
                        if (offset + 1 < token.Length) value = token.Substring(offset + 1);
                        else if (index < args.Length) value = args[index++];
                        else throw Error("SSH option requires an argument.");
                        offset = token.Length;
                    }
                    SshOption option = new SshOption { Name = name, Value = value };
                    if (name == 'o')
                    {
                        ParseConfigOption(option);
                        if (Equal(option.ConfigKey, "user"))
                            result.UserValues.Add(ValidateUser(option.ConfigValue));
                        if (Equal(option.ConfigKey, "port"))
                            result.PortValues.Add(ParsePort(option.ConfigValue));
                    }
                    if (name == 'l') result.UserValues.Add(ValidateUser(value));
                    if (name == 'p') result.PortValues.Add(ParsePort(value));
                    if (name == 'G') result.IsConfig = true;
                    if (name == 'V') result.IsVersion = true;
                    result.Options.Add(option);
                }
            }
            return false;
        }

        private static void ParseDestination(ParsedSsh parsed)
        {
            string target = parsed.Target;
            if (String.IsNullOrEmpty(target)) throw Error("SSH destination is empty.");
            string host = target;
            if (target.StartsWith("ssh://", StringComparison.OrdinalIgnoreCase))
            {
                // Only plain RFC-style host/user/port URI tokens are accepted.
                // Percent-decoding could turn host text into shell metacharacters.
                string authority = target.Substring(6);
                if (authority.EndsWith("/", StringComparison.Ordinal))
                    authority = authority.Substring(0, authority.Length - 1);
                if (authority.IndexOf('/') >= 0 || authority.IndexOf('%') >= 0)
                    throw Error("Unsupported SSH destination URI.");
                int colon = authority.LastIndexOf(':');
                if (colon >= 0 && authority.IndexOf(']') < colon)
                {
                    parsed.PortValues.Add(ParsePort(authority.Substring(colon + 1)));
                    authority = authority.Substring(0, colon);
                }
                host = authority;
            }
            int at = host.LastIndexOf('@');
            if (at >= 0)
            {
                parsed.UserValues.Add(ValidateUser(host.Substring(0, at)));
                host = host.Substring(at + 1);
            }
            if (String.IsNullOrEmpty(host) || host[0] == '-') throw Error("Invalid SSH destination.");
            foreach (char character in host)
                if (Char.IsWhiteSpace(character) || Char.IsControl(character) ||
                    "'\"`$\\;&|<>(){}!#".IndexOf(character) >= 0)
                    throw Error("Invalid character in SSH destination.");
            parsed.Host = host;
        }

        private static void ParseConfigOption(SshOption option)
        {
            string raw = option.Value;
            if (String.IsNullOrWhiteSpace(raw) || raw.IndexOf('\n') >= 0 || raw.IndexOf('\r') >= 0)
                throw Error("Malformed SSH configuration option.");
            int offset = 0;
            while (offset < raw.Length && Char.IsWhiteSpace(raw[offset])) offset++;
            int start = offset;
            while (offset < raw.Length && raw[offset] != '=' && !Char.IsWhiteSpace(raw[offset])) offset++;
            string key = raw.Substring(start, offset - start);
            if (key.Length == 0) throw Error("Malformed SSH configuration option.");
            foreach (char character in key)
                if (!(character >= 'A' && character <= 'Z') &&
                    !(character >= 'a' && character <= 'z') &&
                    !(character >= '0' && character <= '9'))
                    throw Error("Malformed SSH configuration option.");
            while (offset < raw.Length && Char.IsWhiteSpace(raw[offset])) offset++;
            if (offset < raw.Length && raw[offset] == '=') offset++;
            while (offset < raw.Length && Char.IsWhiteSpace(raw[offset])) offset++;
            if (offset >= raw.Length) throw Error("SSH configuration value is missing.");
            string value = raw.Substring(offset).Trim();
            if (value.Length >= 2 && ((value[0] == '"' && value[value.Length - 1] == '"') ||
                (value[0] == '\'' && value[value.Length - 1] == '\'')))
                value = value.Substring(1, value.Length - 2);
            option.ConfigKey = key.ToLowerInvariant();
            option.ConfigValue = value;
        }

        private static void TransformConfig(SshOption option, AdapterSettings settings,
            List<string> output, List<string> audit)
        {
            string key = option.ConfigKey;
            string value = option.ConfigValue;
            switch (key)
            {
                case "hostname":
                    if (!Equal(value, settings.TargetHost)) throw Error("Conflicting hostname for the protected HPC target.");
                    return;
                case "user": case "port": return;
                case "identityfile":
                    ValidateIdentity(value, settings);
                    AddAudit(audit, "windows-identity-removed-use-existing-linux-identity");
                    return;
                case "controlpath": case "controlmaster": case "controlpersist":
                    AddAudit(audit, "control-options-replaced-with-fixed-existing-master");
                    return;
                case "batchmode": case "numberofpasswordprompts":
                case "connectionattempts": case "connecttimeout":
                    AddAudit(audit, "authentication-options-fixed-for-noninteractive-reuse");
                    return;
                case "stricthostkeychecking":
                    if (!Equal(value, "yes") && !Equal(value, "true"))
                        throw Error("Host-key verification may not be weakened.");
                    return;
                case "proxycommand":
                    if (!String.Equals(value, "/bin/false", StringComparison.Ordinal))
                        throw Error("Caller-supplied proxy commands are not allowed.");
                    return;
                case "proxyjump":
                    if (!Equal(value, "none")) throw Error("Proxy jumps are not allowed for the protected HPC target.");
                    return;
                case "canonicalizehostname":
                case "permitlocalcommand":
                case "forwardagent":
                case "forwardx11":
                case "forwardx11trusted":
                case "gatewayports":
                    RequireNo(value);
                    return;
                case "requesttty":
                    RequireNo(value);
                    return;
                case "clearallforwardings":
                    if (!Equal(value, "yes") && !Equal(value, "true"))
                        throw Error("Forwarding must remain disabled for the protected HPC target.");
                    return;
                case "serveraliveinterval":
                case "serveralivecountmax":
                    ValidateNonnegativeNumber(value);
                    AddConfig(output, option.Value);
                    return;
                case "tcpkeepalive": case "compression": case "identitiesonly":
                case "exitonforwardfailure":
                    RequireBoolean(value);
                    AddConfig(output, option.Value);
                    return;
                case "loglevel":
                    if (!In(value, "QUIET", "FATAL", "ERROR", "INFO", "VERBOSE", "DEBUG", "DEBUG1", "DEBUG2", "DEBUG3"))
                        throw Error("Invalid SSH logging level.");
                    AddConfig(output, option.Value);
                    return;
                case "addressfamily":
                    if (!In(value, "any", "inet", "inet6")) throw Error("Invalid SSH address family.");
                    AddConfig(output, option.Value);
                    return;
                case "sessiontype":
                    if (!Equal(value, "default")) throw Error("Alternate SSH session types are not supported.");
                    AddConfig(output, option.Value);
                    return;
                // These options can execute a program, alter trust, create a
                // listener, select a different credential, or add a command.
                // Unknown options fail too; none are silently discarded.
                default:
                    throw Error("SSH configuration option is not supported for the protected HPC target.");
            }
        }

        public static void ValidateSettings(AdapterSettings settings)
        {
            if (settings == null) throw Error("Adapter settings are missing.");
            ValidateToken(settings.Distribution, true);
            ValidateToken(settings.User, false);
            ValidateToken(settings.TargetUser, false);
            ValidateHost(settings.TargetAlias);
            ValidateHost(settings.TargetHost);
            if (settings.TargetPort < 1 || settings.TargetPort > 65535)
                throw Error("Configured target port is invalid.");
            ValidateWindowsPath(settings.WindowsSsh);
            string systemSsh = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "OpenSSH", "ssh.exe");
            if (!String.Equals(Path.GetFullPath(settings.WindowsSsh), Path.GetFullPath(systemSsh), StringComparison.OrdinalIgnoreCase))
                throw Error("Native fallback must be the system Windows OpenSSH executable.");
            ValidateWindowsPath(settings.WindowsConfigPath);
            if (settings.WindowsIdentityPath != null) ValidateWindowsPath(settings.WindowsIdentityPath);
            ValidateLinuxPath(settings.LinuxHome, false);
            ValidateLinuxPath(settings.LinuxSsh, false);
            if (!String.Equals(settings.LinuxSsh, "/usr/bin/ssh", StringComparison.Ordinal))
                throw Error("The Linux transport must be /usr/bin/ssh.");
            ValidateLinuxPath(settings.LinuxConfig, false);
            ValidateLinuxPath(settings.ControlPath, true);
            if (settings.LinuxHome == "/" || settings.LinuxHome.EndsWith("/", StringComparison.Ordinal))
                throw Error("A non-root Linux home without a trailing slash is required.");
            string sshDirectory = settings.LinuxHome + "/.ssh/";
            if (!settings.ControlPath.StartsWith(sshDirectory, StringComparison.Ordinal) ||
                !settings.LinuxConfig.StartsWith(sshDirectory, StringComparison.Ordinal))
                throw Error("Control path is outside the protected Linux SSH directory.");
            // Keep OpenSSH's endpoint-derived hash expansion, but no arbitrary
            // environment, user or command expansions in configuration values.
            string unexpanded = settings.ControlPath.Replace("%C", "");
            if (unexpanded.IndexOf('%') >= 0)
                throw Error("Unsupported control-path expansion.");
        }

        private static void ValidateLinuxPath(string path, bool allowPercent)
        {
            if (String.IsNullOrEmpty(path) || path[0] != '/' || path.EndsWith("/", StringComparison.Ordinal))
                throw Error("An absolute Linux path is required.");
            foreach (char c in path)
                if (!AsciiLetterOrDigit(c) && "_./@+-".IndexOf(c) < 0 && !(allowPercent && c == '%'))
                    throw Error("Linux paths must use plain absolute path characters.");
            string[] segments = path.Split('/');
            for (int i = 1; i < segments.Length; i++)
                if (segments[i].Length == 0 || segments[i] == "." || segments[i] == "..")
                    throw Error("Linux paths must not contain empty or dot segments.");
        }

        private static bool AsciiLetterOrDigit(char c)
        {
            return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
        }

        private static void ValidateToken(string value, bool allowSpace)
        {
            if (String.IsNullOrWhiteSpace(value) || value[0] == '-' || value != value.Trim())
                throw Error("A configured identity or distribution is invalid.");
            foreach (char c in value)
                if (!AsciiLetterOrDigit(c) && "_.-".IndexOf(c) < 0 && !(allowSpace && c == ' '))
                    throw Error("A configured identity or distribution contains unsupported characters.");
        }

        private static void ValidateHost(string value)
        {
            ValidateToken(value, false);
            // This adapter deliberately supports DNS names, IPv4 and aliases.
            // IPv6 literals require a separately reviewed endpoint parser.
            if (value[0] == '.' || value.EndsWith(".", StringComparison.Ordinal) || value.IndexOf("..", StringComparison.Ordinal) >= 0)
                throw Error("A configured host or alias is invalid.");
        }

        private static void ValidateWindowsPath(string value)
        {
            if (String.IsNullOrEmpty(value) || value.Length < 3 ||
                !((value[0] >= 'A' && value[0] <= 'Z') || (value[0] >= 'a' && value[0] <= 'z')) ||
                value[1] != ':' || (value[2] != '\\' && value[2] != '/'))
                throw Error("A fully qualified local Windows path is required.");
            foreach (char c in value)
                if (Char.IsControl(c) || "\"<>|*?%".IndexOf(c) >= 0)
                    throw Error("A Windows path contains unsupported characters.");
            if (value.IndexOf(':', 2) >= 0) throw Error("Alternate data stream paths are not supported.");
            Path.GetFullPath(value);
        }

        private static void ValidateIdentity(string value, AdapterSettings settings)
        {
            if (!SameWindowsPath(value, settings.WindowsIdentityPath))
                throw Error("Unrecognized identity path for the protected HPC target.");
        }

        private static bool SameWindowsPath(string first, string second)
        {
            if (String.IsNullOrEmpty(first) || String.IsNullOrEmpty(second)) return false;
            // Do not resolve relative paths against a changing working directory.
            if (!Path.IsPathRooted(first) || !Path.IsPathRooted(second)) return false;
            try
            {
                return String.Equals(Path.GetFullPath(first), Path.GetFullPath(second), StringComparison.OrdinalIgnoreCase);
            }
            catch (ArgumentException) { return false; }
            catch (NotSupportedException) { return false; }
            catch (PathTooLongException) { return false; }
        }

        private static string ValidateUser(string value)
        {
            if (String.IsNullOrEmpty(value) || value[0] == '-') throw Error("Invalid SSH user.");
            foreach (char character in value)
                if (Char.IsWhiteSpace(character) || Char.IsControl(character) ||
                    "'\"`$\\;&|<>(){}!#@".IndexOf(character) >= 0)
                    throw Error("Invalid character in SSH user.");
            return value;
        }

        private static int ParsePort(string value)
        {
            int port;
            if (!Int32.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out port) || port < 1 || port > 65535)
                throw Error("SSH port is invalid.");
            return port;
        }

        private static void ValidateNonnegativeNumber(string value)
        {
            int number;
            if (!Int32.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out number) || number < 0)
                throw Error("SSH numeric option is invalid.");
        }

        private static void RequireNo(string value)
        {
            if (!Equal(value, "no") && !Equal(value, "false"))
                throw Error("SSH feature must remain disabled for the protected HPC target.");
        }

        private static void RequireBoolean(string value)
        {
            if (!In(value, "yes", "no", "true", "false")) throw Error("SSH boolean option is invalid.");
        }

        private static bool In(string value, params string[] choices)
        {
            foreach (string choice in choices) if (Equal(value, choice)) return true;
            return false;
        }

        private static bool Equal(string first, string second)
        {
            return String.Equals(first, second, StringComparison.OrdinalIgnoreCase);
        }

        private static void AddConfig(List<string> output, string value)
        {
            output.Add("-o"); output.Add(value);
        }

        private static void AddAudit(List<string> audit, string value)
        {
            if (!audit.Contains(value)) audit.Add(value);
        }

        private static string[] Slice(string[] input, int start)
        {
            string[] output = new string[input.Length - start];
            Array.Copy(input, start, output, 0, output.Length);
            return output;
        }

        private static ArgumentException Error(string message)
        {
            // All messages are constant descriptions. Never echo argument values
            // because a remote command or an unsupported option may contain data.
            return new ArgumentException(message);
        }
    }
}
