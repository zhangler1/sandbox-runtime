using System;
using System.Collections.Generic;
using System.Text;
using System.Threading;

internal static class Program
{
    private static int Main(string[] args)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        try
        {
            if (args.Length == 1 && (args[0] == "--help" || args[0] == "help"))
            {
                Console.WriteLine("bank-sandbox 0.3.0-preview (Windows x64 AppContainer)\n" +
                    "  prepare|remove --workspace <absolute local directory>\n" +
                    "  status|plan --workspace <directory> [--json]\n" +
                    "  run --workspace <directory> --shell cmd|powershell --command <text> [--timeout-ms 30000]\n" +
                    "  run --workspace <directory> --exec <absolute local EXE> [--arg <value> ...] [--timeout-ms 30000]\n" +
                    "No local SAM account is created. No network capabilities are granted. Git Bash is unsupported.");
                return 0;
            }
            if (args.Length == 0 || Array.IndexOf(new[] { "prepare", "status", "plan", "remove", "run" }, args[0]) < 0)
                throw new ArgumentException("expected prepare, status, plan, remove, run or --help");
            var values = new Dictionary<string, string>();
            var directArguments = new List<string>();
            bool json = false;
            for (int i = 1; i < args.Length; )
            {
                string name = args[i];
                if (name == "--json") { if (json) throw new ArgumentException("duplicate --json"); json = true; i++; continue; }
                if (name == "--arg")
                {
                    if (i + 1 >= args.Length) throw new ArgumentException("incomplete option: --arg");
                    directArguments.Add(args[i + 1]); i += 2; continue;
                }
                if (Array.IndexOf(new[] { "--workspace", "--shell", "--command", "--exec", "--timeout-ms" }, name) < 0 || values.ContainsKey(name) || i + 1 >= args.Length)
                    throw new ArgumentException("unknown, duplicate or incomplete option: " + name);
                values.Add(name, args[i + 1]);
                i += 2;
            }
            string workspace;
            if (!values.TryGetValue("--workspace", out workspace)) throw new ArgumentException("--workspace is required");
            workspace = args[0] == "status" ? Policy.NormalizeWorkspacePath(workspace) : Policy.NormalizeWorkspace(workspace);
            Policy.CheckHost();
            bool mutating = args[0] == "prepare" || args[0] == "remove";
            using (var topology = mutating ? LockLease.Acquire("Topology", 30000) : null)
            using (var workspaceLock = LockLease.Acquire(Policy.Moniker(workspace), 1000))
            {
                if (args[0] != "run")
                {
                    if (values.Count != 1 || directArguments.Count != 0) throw new ArgumentException("only --workspace is valid for this action");
                    if (json && args[0] != "status" && args[0] != "plan") throw new ArgumentException("--json is valid only for status and plan");
                    if (args[0] == "prepare") { Policy.Prepare(workspace); return Policy.Status(workspace) ? 0 : 125; }
                    if (args[0] == "status") return Policy.Status(workspace, json) ? 0 : 125;
                    if (args[0] == "plan") return Policy.Plan(workspace, json) ? 0 : 125;
                    Policy.Remove(workspace); Console.WriteLine("removed=true"); return 0;
                }
                if (json) throw new ArgumentException("--json is valid only for status and plan");
                string shell, command, executable, rawTimeout;
                int timeout = 30000;
                if (values.TryGetValue("--timeout-ms", out rawTimeout) && (!Int32.TryParse(rawTimeout, out timeout) || timeout < 1 || timeout > 300000))
                    throw new ArgumentException("timeout-ms must be an integer from 1 to 300000");
                if (values.TryGetValue("--exec", out executable))
                {
                    if (values.ContainsKey("--shell") || values.ContainsKey("--command"))
                        throw new ArgumentException("--exec cannot be combined with --shell or --command");
                    return Runner.RunExecutable(workspace, executable, directArguments, timeout);
                }
                if (directArguments.Count != 0 || !values.TryGetValue("--shell", out shell) ||
                    !values.TryGetValue("--command", out command) || String.IsNullOrWhiteSpace(command))
                    throw new ArgumentException("run requires --shell and nonempty --command, or --exec");
                return Runner.Run(workspace, shell, command, timeout);
            }
        }
        catch (Exception error) { Console.Error.WriteLine("bank-sandbox: " + error.Message); return 125; }
    }
}
