using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

internal static class Runner
{
    private const int OutputLimit = 1024 * 1024;

    private static byte[] ReadPipe(IntPtr handle, IntPtr job, Action exceeded)
    {
        using (var stream = new FileStream(new SafeFileHandle(handle, true), FileAccess.Read))
        using (var output = new MemoryStream())
        {
            var buffer = new byte[8192];
            int count;
            while ((count = stream.Read(buffer, 0, buffer.Length)) != 0)
            {
                if (output.Length + count > OutputLimit)
                { exceeded(); Native.TerminateJobObject(job, 125); break; }
                output.Write(buffer, 0, count);
            }
            return output.ToArray();
        }
    }

    private static string Decode(byte[] data)
    {
        try { return new UTF8Encoding(false, true).GetString(data); }
        catch (DecoderFallbackException) { return Encoding.GetEncoding((int)Native.GetOEMCP()).GetString(data); }
    }

    internal static int Run(string workspace, string shell, string command, int timeout)
    {
        string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        string executable, arguments;
        if (shell == "cmd")
        {
            executable = Path.Combine(windows, "System32", "cmd.exe");
            arguments = "/d /s /c \"" + command + "\"";
        }
        else if (shell == "powershell")
        {
            executable = Path.Combine(windows, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
            string script = "$ProgressPreference='SilentlyContinue'; $ErrorActionPreference='Stop'; " +
                "[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false); try { " +
                "New-PSDrive -Name BankWorkspace -PSProvider FileSystem -Root '" + workspace.Replace("'", "''") + "' -Scope Global -ErrorAction Stop | Out-Null; " +
                "Set-Location -LiteralPath 'BankWorkspace:\\' -ErrorAction Stop; " + command +
                "; if ($LASTEXITCODE -is [int]) { exit $LASTEXITCODE } } catch { [Console]::Error.WriteLine(($_ | Out-String)); exit 1 }";
            arguments = "-NoLogo -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
        }
        else throw new ArgumentException("unsupported shell: " + shell + "; supported shells: cmd, powershell");

        return RunProcess(workspace, executable, arguments, timeout);
    }

    internal static int RunExecutable(string workspace, string executable, IList<string> arguments, int timeout)
    {
        if (String.IsNullOrWhiteSpace(executable) || executable.Length < 4 ||
            !Char.IsLetter(executable[0]) || executable[1] != ':' || executable[2] != '\\' ||
            !String.Equals(Path.GetExtension(executable), ".exe", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("--exec must be an absolute local .exe path");
        if (executable.IndexOf('\0') >= 0 || !File.Exists(executable))
            throw new ArgumentException("--exec must name an existing local .exe file");
        var drive = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(executable)));
        if (drive.DriveType != DriveType.Fixed)
            throw new ArgumentException("--exec must be on a local fixed drive");
        var command = new StringBuilder();
        foreach (string argument in arguments)
        {
            if (argument == null || argument.IndexOf('\0') >= 0)
                throw new ArgumentException("--arg cannot contain a NUL character");
            command.Append(' ').Append(QuoteArgument(argument));
        }
        return RunProcess(workspace, executable, command.ToString(), timeout);
    }

    private static string QuoteArgument(string value)
    {
        if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0) return value;
        var result = new StringBuilder("\"");
        int slashes = 0;
        foreach (char character in value)
        {
            if (character == '\\') { slashes++; continue; }
            if (character == '"')
            {
                result.Append('\\', slashes * 2 + 1).Append('"');
                slashes = 0;
                continue;
            }
            result.Append('\\', slashes).Append(character);
            slashes = 0;
        }
        result.Append('\\', slashes * 2).Append('"');
        return result.ToString();
    }

    private static int RunProcess(string workspace, string executable, string arguments, int timeout)
    {
        string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);

        IntPtr sid = Policy.Derive(Policy.Moniker(workspace));
        IntPtr attributes = IntPtr.Zero, capabilities = IntPtr.Zero, handles = IntPtr.Zero, job = IntPtr.Zero, environment = IntPtr.Zero;
        IntPtr stdoutRead = IntPtr.Zero, stdoutWrite = IntPtr.Zero, stderrRead = IntPtr.Zero, stderrWrite = IntPtr.Zero, input = IntPtr.Zero;
        Native.ProcessInfo process = new Native.ProcessInfo();
        bool initialized = false, finished = false;
        Task<byte[]> stdout = null, stderr = null;
        int outputExceeded = 0, cancelled = 0;
        ConsoleCancelEventHandler cancel = null;
        try
        {
            var expected = new SecurityIdentifier(sid);
            if (!Policy.ProfileExists(expected) || !Policy.HasGrant(workspace, expected))
                throw new InvalidOperationException("workspace is not ready; run prepare first");
            Policy.CheckTreeForGrant(workspace);
            Policy.CheckNoOverlappingPackageGrant(workspace, expected);

            string profile = Policy.ProfileFolder(expected);
            string temp = Path.Combine(profile, "Temp");
            Policy.CheckDirectoryChain(profile);
            Policy.CheckTreeForGrant(Policy.ProfileTreeRoot(profile));
            if (File.Exists(temp)) throw new IOException("profile Temp is not a directory");
            if (Directory.Exists(temp)) Policy.CheckDirectoryChain(temp);
            Directory.CreateDirectory(temp);
            Policy.CheckDirectoryChain(temp);
            var variables = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
                { "SystemRoot", windows }, { "WINDIR", windows },
                { "ComSpec", Path.Combine(windows, "System32", "cmd.exe") },
                { "PATH", Path.Combine(windows, "System32") + ";" + windows + ";" + Path.Combine(windows, "System32", "WindowsPowerShell", "v1.0") },
                { "PATHEXT", ".COM;.EXE;.BAT;.CMD" }, { "TEMP", temp }, { "TMP", temp },
                // Windows rebases AppContainer known folders during process creation.
                // Supply normal base folders here; pre-rebasing LOCALAPPDATA would append the package path twice.
                { "LOCALAPPDATA", Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData) },
                { "APPDATA", Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData) },
                { "USERPROFILE", Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) },
                { "USERNAME", Environment.UserName }, { "PROCESSOR_ARCHITECTURE", "AMD64" }
            };
            var block = new StringBuilder();
            foreach (var variable in variables) block.Append(variable.Key).Append('=').Append(variable.Value).Append('\0');
            block.Append('\0');
            environment = Marshal.StringToHGlobalUni(block.ToString());

            job = Native.CreateJobObjectW(IntPtr.Zero, null);
            if (job == IntPtr.Zero) Policy.Fail("CreateJobObject");
            var limits = new Native.JobLimits();
            limits.Basic.Flags = 0x2000; // KILL_ON_JOB_CLOSE; no breakaway flags.
            if (!Native.SetInformationJobObject(job, 9, ref limits, Marshal.SizeOf(typeof(Native.JobLimits)))) Policy.Fail("SetInformationJobObject");

            var security = new Native.SecurityAttributes { Size = Marshal.SizeOf(typeof(Native.SecurityAttributes)), Inherit = true };
            if (!Native.CreatePipe(out stdoutRead, out stdoutWrite, ref security, 0)) Policy.Fail("CreatePipe(stdout)");
            if (!Native.CreatePipe(out stderrRead, out stderrWrite, ref security, 0)) Policy.Fail("CreatePipe(stderr)");
            if (!Native.SetHandleInformation(stdoutRead, 1, 0) || !Native.SetHandleInformation(stderrRead, 1, 0)) Policy.Fail("SetHandleInformation");
            input = Native.CreateFileW("NUL", 0x80000000, 3, ref security, 3, 0, IntPtr.Zero);
            if (input == new IntPtr(-1)) { input = IntPtr.Zero; Policy.Fail("CreateFile(NUL)"); }

            IntPtr size = IntPtr.Zero;
            Native.InitializeProcThreadAttributeList(IntPtr.Zero, 2, 0, ref size);
            if (size == IntPtr.Zero) Policy.Fail("InitializeProcThreadAttributeList(size)");
            attributes = Marshal.AllocHGlobal(size);
            if (!Native.InitializeProcThreadAttributeList(attributes, 2, 0, ref size)) Policy.Fail("InitializeProcThreadAttributeList");
            initialized = true;
            capabilities = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Native.Capabilities)));
            Marshal.StructureToPtr(new Native.Capabilities { Sid = sid }, capabilities, false);
            if (!Native.UpdateProcThreadAttribute(attributes, 0, (IntPtr)0x20009, capabilities,
                (IntPtr)Marshal.SizeOf(typeof(Native.Capabilities)), IntPtr.Zero, IntPtr.Zero)) Policy.Fail("UpdateProcThreadAttribute(capabilities)");
            handles = Marshal.AllocHGlobal(IntPtr.Size * 3);
            Marshal.WriteIntPtr(handles, 0, input);
            Marshal.WriteIntPtr(handles, IntPtr.Size, stdoutWrite);
            Marshal.WriteIntPtr(handles, IntPtr.Size * 2, stderrWrite);
            if (!Native.UpdateProcThreadAttribute(attributes, 0, (IntPtr)0x20002, handles,
                (IntPtr)(IntPtr.Size * 3), IntPtr.Zero, IntPtr.Zero)) Policy.Fail("UpdateProcThreadAttribute(handles)");
            var startup = new Native.StartupInfoEx { Attributes = attributes };
            startup.Info.Size = Marshal.SizeOf(typeof(Native.StartupInfoEx));
            startup.Info.Flags = 0x100; // STARTF_USESTDHANDLES
            startup.Info.Input = input; startup.Info.Output = stdoutWrite; startup.Info.Error = stderrWrite;
            if (!Native.CreateProcessW(executable, new StringBuilder(QuoteArgument(executable) + " " + arguments),
                IntPtr.Zero, IntPtr.Zero, true, 0x80000 | 4 | 0x08000000 | 0x400, environment, workspace, ref startup, out process))
                Policy.Fail("CreateProcess(AppContainer)");

            // The process is still suspended: reject a wrong token before any command code runs.
            Policy.CheckChild(process.Process, expected);
            if (!Native.AssignProcessToJobObject(job, process.Process)) Policy.Fail("AssignProcessToJobObject");
            Native.CloseHandle(stdoutWrite); stdoutWrite = IntPtr.Zero;
            Native.CloseHandle(stderrWrite); stderrWrite = IntPtr.Zero;
            Native.CloseHandle(input); input = IntPtr.Zero;
            IntPtr readOut = stdoutRead, readErr = stderrRead;
            stdoutRead = stderrRead = IntPtr.Zero;
            stdout = Task.Factory.StartNew(() => ReadPipe(readOut, job, () => Interlocked.Exchange(ref outputExceeded, 1)));
            stderr = Task.Factory.StartNew(() => ReadPipe(readErr, job, () => Interlocked.Exchange(ref outputExceeded, 1)));
            cancel = (sender, args) => { args.Cancel = true; Interlocked.Exchange(ref cancelled, 1); Native.TerminateJobObject(job, 130); };
            Console.CancelKeyPress += cancel;
            if (Native.ResumeThread(process.Thread) == 0xffffffff) Policy.Fail("ResumeThread");
            uint wait = Native.WaitForSingleObject(process.Process, (uint)timeout);
            if (wait != 0 && wait != 258) Policy.Fail("WaitForSingleObject");
            bool timedOut = wait == 258;
            Native.TerminateJobObject(job, timedOut ? 124u : 125u); // close background descendants and their pipe handles, too.
            if (Native.WaitForSingleObject(process.Process, 5000) != 0) throw new IOException("child did not terminate");
            uint code;
            if (!Native.GetExitCodeProcess(process.Process, out code)) Policy.Fail("GetExitCodeProcess");
            if (!Task.WaitAll(new Task[] { stdout, stderr }, 5000)) throw new IOException("child output pipes did not close");
            Console.Out.Write(Decode(stdout.Result));
            Console.Error.Write(Decode(stderr.Result));
            finished = true;
            if (cancelled != 0) return 130;
            if (timedOut) { Console.Error.WriteLine("bank-sandbox: command timed out"); return 124; }
            if (outputExceeded != 0) { Console.Error.WriteLine("bank-sandbox: output exceeded 1 MiB per stream"); return 125; }
            return unchecked((int)code);
        }
        finally
        {
            if (cancel != null) Console.CancelKeyPress -= cancel;
            if (!finished && process.Process != IntPtr.Zero) { Native.TerminateProcess(process.Process, 125); Native.WaitForSingleObject(process.Process, 5000); }
            if (job != IntPtr.Zero) Native.TerminateJobObject(job, 125);
            foreach (IntPtr handle in new[] { input, stdoutRead, stdoutWrite, stderrRead, stderrWrite, process.Thread, process.Process })
                if (handle != IntPtr.Zero) Native.CloseHandle(handle);
            try
            {
                if (stdout != null && stderr != null) Task.WaitAll(new Task[] { stdout, stderr }, 5000);
            }
            finally
            {
                if (job != IntPtr.Zero) Native.CloseHandle(job);
                if (initialized) Native.DeleteProcThreadAttributeList(attributes);
                foreach (IntPtr memory in new[] { attributes, capabilities, handles, environment }) if (memory != IntPtr.Zero) Marshal.FreeHGlobal(memory);
                Native.FreeSid(sid);
            }
        }
    }
}
