using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;

namespace ApocritaAdapter
{
    public static class Program
    {
        static readonly string Invocation = Guid.NewGuid().ToString("N");
        static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 65536 };
        static string logPath;

        static void Error(string text)
        {
            byte[] bytes = new UTF8Encoding(false).GetBytes(text + "\n");
            Stream stream = Console.OpenStandardError();
            stream.Write(bytes, 0, bytes.Length); stream.Flush();
        }

        static void Log(string phase, string operation, string route, int? exitCode)
        {
            // Opt-in only. No host/user/path, command, arguments, streams,
            // authentication, environment, process ancestry or process IDs.
            if (logPath == null) return;
            try {
                var item = new { utc = DateTime.UtcNow.ToString("o"), id = Invocation,
                    phase = phase, operation = operation, route = route, exitCode = exitCode };
                File.AppendAllText(logPath, Json.Serialize(item) + "\n", new UTF8Encoding(false));
            } catch { /* Logging failures must never enter the protocol stream. */ }
        }

        public static AdapterSettings LoadSettings(string path)
        {
            if (!Path.IsPathRooted(path)) throw new ArgumentException("Configuration path must be absolute.");
            string payload;
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                if (stream.Length > 65536) throw new ArgumentException("Configuration exceeds the size limit.");
                using (var reader = new StreamReader(stream, new UTF8Encoding(false, true), true))
                    payload = reader.ReadToEnd();
            }
            var fields = Json.DeserializeObject(payload) as Dictionary<string, object>;
            if (fields == null) throw new ArgumentException("Configuration must be a JSON object.");
            var required = new HashSet<string>(new[] { "Distribution", "User", "LinuxHome", "TargetAlias",
                "TargetHost", "TargetUser", "TargetPort", "LinuxSsh", "LinuxConfig", "ControlPath",
                "WindowsConfigPath", "WindowsSsh" }, StringComparer.Ordinal);
            foreach (KeyValuePair<string, object> field in fields) {
                if (field.Key == "MetadataLogging") {
                    if (!(field.Value is bool)) throw new ArgumentException("MetadataLogging must be boolean.");
                } else if (field.Key == "WindowsIdentityPath") {
                    if (field.Value != null && !(field.Value is string)) throw new ArgumentException("Identity path must be text or null.");
                } else {
                    if (!required.Remove(field.Key)) throw new ArgumentException("Unknown configuration field.");
                    if (field.Key == "TargetPort") {
                        if (!(field.Value is int)) throw new ArgumentException("TargetPort must be an integer.");
                    } else if (!(field.Value is string)) throw new ArgumentException("Configuration field must be text.");
                }
            }
            if (required.Count != 0) throw new ArgumentException("Required configuration field is missing.");
            AdapterSettings settings = Json.Deserialize<AdapterSettings>(payload);
            SshArguments.ValidateSettings(settings);
            string executable = Process.GetCurrentProcess().MainModule.FileName;
            if (String.Equals(Path.GetFullPath(executable), Path.GetFullPath(settings.WindowsSsh), StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException("Native SSH fallback recursion refused.");
            return settings;
        }

        public static int Main(string[] args)
        {
            string operation = "invalid", route = "none";
            try {
                // Installation-time validation is local and read-only. This
                // branch cannot start a process, create a log, or authenticate.
                if (args.Length > 0 && args[0] == "--validate-config") {
                    if (args.Length != 2) throw new ArgumentException("A configuration file is required.");
                    LoadSettings(args[1]);
                    Console.WriteLine("ADAPTER_CONFIG_VALID"); return 0;
                }
                string executable = Process.GetCurrentProcess().MainModule.FileName;
                string root = Directory.GetParent(Path.GetDirectoryName(executable)).FullName;
                AdapterSettings settings = LoadSettings(Path.Combine(root, "adapter-config.json"));
                ParsedSsh parsed = SshArguments.Parse(args, settings);
                operation = parsed.Operation; route = parsed.IsTarget ? "wsl" : "windows";
                string[] linuxArgs = parsed.IsTarget ? SshArguments.BuildLinuxArguments(parsed, settings) : null;
                if (settings.MetadataLogging) {
                    string logs = Path.Combine(root, "logs");
                    try {
                        Directory.CreateDirectory(logs);
                        logPath = Path.Combine(logs, DateTime.UtcNow.ToString("yyyyMMddTHHmmssfff") + "-" + Invocation + ".jsonl");
                    } catch { /* Optional metadata cannot block the transport. */ }
                }
                Log("start", operation, route, null);
                int result;
                if (!parsed.IsTarget) {
                    result = NativeProcess.Run(settings.WindowsSsh, args, 0, false, null);
                } else {
                    string wsl = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "wsl.exe");
                    var prefix = new List<string> { "--distribution", settings.Distribution, "--user", settings.User,
                        "--exec", settings.LinuxSsh };
                    if (!parsed.IsConfig) {
                        var check = new List<string>(prefix);
                        ParsedSsh checkRequest = SshArguments.Parse(new[] { "-O", "check", settings.TargetAlias }, settings);
                        check.AddRange(SshArguments.BuildLinuxArguments(checkRequest, settings));
                        if (NativeProcess.Run(wsl, check.ToArray(), 15000, true, null) != 0) {
                            Error("APOCRITA_REAUTH_REQUIRED: WSL SSH master is unavailable. Authenticate in your trusted terminal, then retry. No password will be requested here.");
                            Log("exit", operation, route, 255); return 255;
                        }
                    }
                    prefix.AddRange(linuxArgs);
                    result = NativeProcess.Run(wsl, prefix.ToArray(), 0, false, null);
                    if (result == 255 && !parsed.IsConfig)
                        Error("APOCRITA_SSH_FAILED: the shared connection failed. Check the WSL master in a trusted terminal. Automatic fresh authentication is disabled.");
                }
                Log("exit", operation, route, result); return result;
            }
            catch (Exception exception) {
                // Exception messages can contain caller data or local paths.
                Error("APOCRITA_ADAPTER_REFUSED: invalid SSH request or configuration (" + exception.GetType().Name + "). See the adapter README.");
                Log("exit", operation, route, 64); return 64;
            }
        }
    }
}
