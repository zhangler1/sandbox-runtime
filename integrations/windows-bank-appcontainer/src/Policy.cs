using System;
using System.ComponentModel;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;

internal static class Policy
{
    internal static void CheckHost()
    {
        if (IntPtr.Size != 8) throw new InvalidOperationException("Windows x64 is required");
        IntPtr token;
        if (!Native.OpenProcessToken(Native.GetCurrentProcess(), 8, out token)) Fail("OpenProcessToken(host)");
        try
        {
            IntPtr data = TokenInfo(token, 29);
            try { if (Marshal.ReadInt32(data) != 0) throw new InvalidOperationException("Run from a normal host terminal; parent is already an AppContainer"); }
            finally { Marshal.FreeHGlobal(data); }
        }
        finally { Native.CloseHandle(token); }
    }

    internal static string NormalizeWorkspace(string input)
    {
        string path = NormalizeWorkspacePath(input);
        if (!Directory.Exists(path)) throw new DirectoryNotFoundException("workspace must already exist");
        return path;
    }

    internal static string NormalizeWorkspacePath(string input)
    {
        if (String.IsNullOrWhiteSpace(input) || input.Length < 3 || input[1] != ':' || (input[2] != '\\' && input[2] != '/'))
            throw new ArgumentException("workspace must be an absolute local drive path");
        string path = Path.GetFullPath(input).TrimEnd('\\');
        if (path.Length <= 2 || path.Equals(Path.GetPathRoot(path).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("workspace cannot be a drive root");
        var drive = new DriveInfo(Path.GetPathRoot(path));
        if (drive.DriveType == DriveType.Network || !drive.DriveFormat.Equals("NTFS", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("workspace must be on a local NTFS volume");
        string existing = path;
        while (!Directory.Exists(existing))
        {
            existing = Path.GetDirectoryName(existing);
            if (String.IsNullOrEmpty(existing)) throw new DirectoryNotFoundException("workspace drive does not exist");
        }
        CheckDirectoryChain(existing);
        string runner = Assembly.GetExecutingAssembly().Location;
        if (runner.StartsWith(path + "\\", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("runner must be outside the writable workspace");
        return path;
    }

    internal static void CheckDirectoryChain(string path)
    {
        for (var directory = new DirectoryInfo(path); directory != null; directory = directory.Parent)
            if ((directory.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new ArgumentException("directory path contains a reparse point: " + directory.FullName);
    }

    internal static string Moniker(string workspace)
    {
        using (var hash = SHA256.Create())
            return "BankAgentSandbox_v1_" + BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(workspace.ToUpperInvariant()))).Replace("-", "").Substring(0, 32);
    }

    internal static IntPtr Derive(string name)
    {
        IntPtr sid;
        int hr = Native.DeriveAppContainerSidFromAppContainerName(name, out sid);
        if (hr != 0) Marshal.ThrowExceptionForHR(hr);
        return sid;
    }

    internal static FileSystemAccessRule Grant(SecurityIdentifier sid)
    {
        return new FileSystemAccessRule(sid, FileSystemRights.Modify,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow);
    }

    private static bool IsExactGrant(FileSystemAccessRule rule, SecurityIdentifier sid)
    {
        FileSystemAccessRule expected = Grant(sid);
        return !rule.IsInherited && rule.IdentityReference.Equals(sid) &&
            rule.AccessControlType == expected.AccessControlType &&
            rule.FileSystemRights == expected.FileSystemRights &&
            rule.InheritanceFlags == expected.InheritanceFlags &&
            rule.PropagationFlags == expected.PropagationFlags;
    }

    internal static bool HasGrant(string workspace, SecurityIdentifier sid)
    {
        foreach (FileSystemAccessRule rule in Directory.GetAccessControl(workspace).GetAccessRules(true, false, typeof(SecurityIdentifier)))
            if (IsExactGrant(rule, sid)) return true;
        return false;
    }

    internal static bool ProfileExists(SecurityIdentifier sid)
    {
        IntPtr path;
        int hr = Native.GetAppContainerFolderPath(sid.Value, out path);
        if (hr == unchecked((int)0x80070002)) return false;
        if (hr != 0) Marshal.ThrowExceptionForHR(hr);
        try { return Directory.Exists(Marshal.PtrToStringUni(path)); }
        finally { Marshal.FreeCoTaskMem(path); }
    }

    internal static string ProfileFolder(SecurityIdentifier sid)
    {
        IntPtr path;
        int hr = Native.GetAppContainerFolderPath(sid.Value, out path);
        if (hr != 0) Marshal.ThrowExceptionForHR(hr);
        try { return Marshal.PtrToStringUni(path); }
        finally { Marshal.FreeCoTaskMem(path); }
    }

    internal static string ProfileTreeRoot(string profileFolder)
    {
        return String.Equals(Path.GetFileName(profileFolder), "AC", StringComparison.OrdinalIgnoreCase)
            ? Path.GetDirectoryName(profileFolder) : profileFolder;
    }

    // Inheritable grants affect the file object, including all its hard-link aliases.
    // Reject aliases and reparse points before propagating a new grant.
    internal static void CheckTreeForGrant(string directory)
    {
        foreach (string entry in Directory.EnumerateFileSystemEntries(directory))
        {
            FileAttributes attributes = File.GetAttributes(entry);
            if ((attributes & FileAttributes.ReparsePoint) != 0) throw new ArgumentException("workspace tree contains a reparse point: " + entry);
            if ((attributes & FileAttributes.Directory) != 0) { CheckTreeForGrant(entry); continue; }
            var security = new Native.SecurityAttributes { Size = Marshal.SizeOf(typeof(Native.SecurityAttributes)) };
            IntPtr file = Native.CreateFileW(entry, 0x80, 7, ref security, 3, 0x00200000, IntPtr.Zero);
            if (file == new IntPtr(-1)) Fail("CreateFile(workspace link check)");
            try
            {
                Native.FileInformation information;
                if (!Native.GetFileInformationByHandle(file, out information)) Fail("GetFileInformationByHandle");
                if (information.Links != 1) throw new ArgumentException("workspace contains a hard-linked file: " + entry);
            }
            finally { Native.CloseHandle(file); }
        }
    }

    private static void CheckPackageRules(FileSystemSecurity acl, string path, SecurityIdentifier ownSid, bool candidateRoot, bool descendant)
    {
        foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier)))
        {
            var identity = (SecurityIdentifier)rule.IdentityReference;
            bool package = identity.Value.StartsWith("S-1-15-2-", StringComparison.Ordinal);
            bool capability = identity.Value.StartsWith("S-1-15-3-", StringComparison.Ordinal);
            if (!package && !capability) continue;
            if (rule.AccessControlType == AccessControlType.Deny && identity.Equals(ownSid))
                throw new InvalidOperationException("AppContainer deny rule at: " + path);
            if (rule.AccessControlType != AccessControlType.Allow) continue;
            if (candidateRoot && IsExactGrant(rule, ownSid)) continue;
            if (descendant && rule.IsInherited && identity.Equals(ownSid) &&
                rule.FileSystemRights == Grant(ownSid).FileSystemRights) continue;
            throw new InvalidOperationException("overlapping or broad AppContainer access grant at: " + path + " (" + identity.Value + ")");
        }
    }

    private static void CheckPackageRules(string directory, SecurityIdentifier ownSid, bool candidateRoot, bool descendant)
    {
        CheckPackageRules(Directory.GetAccessControl(directory), directory, ownSid, candidateRoot, descendant);
    }

    private static void CheckDescendantPackageRules(string directory, SecurityIdentifier ownSid)
    {
        foreach (string child in Directory.EnumerateFileSystemEntries(directory))
        {
            FileAttributes attributes = File.GetAttributes(child);
            if ((attributes & FileAttributes.ReparsePoint) != 0)
                throw new ArgumentException("workspace tree contains a reparse point: " + child);
            if ((attributes & FileAttributes.Directory) != 0)
            {
                CheckPackageRules(child, ownSid, false, true);
                CheckDescendantPackageRules(child, ownSid);
            }
            else CheckPackageRules(File.GetAccessControl(child), child, ownSid, false, true);
        }
    }

    internal static void CheckNoOverlappingPackageGrant(string workspace, SecurityIdentifier ownSid)
    {
        CheckPackageRules(workspace, ownSid, true, false);
        for (var ancestor = Directory.GetParent(workspace); ancestor != null; ancestor = ancestor.Parent)
        {
            if ((ancestor.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new ArgumentException("directory path contains a reparse point: " + ancestor.FullName);
            CheckPackageRules(ancestor.FullName, ownSid, false, false);
        }
        CheckDescendantPackageRules(workspace, ownSid);
    }

    internal static void Prepare(string workspace)
    {
        CheckTreeForGrant(workspace);
        string name = Moniker(workspace);
        IntPtr expectedSid = Derive(name);
        try { CheckNoOverlappingPackageGrant(workspace, new SecurityIdentifier(expectedSid)); }
        finally { Native.FreeSid(expectedSid); }
        IntPtr sid;
        int hr = Native.CreateAppContainerProfile(name, name, "Bank agent workspace sandbox", IntPtr.Zero, 0, out sid);
        if (hr == unchecked((int)0x800700B7)) sid = Derive(name);
        else if (hr != 0) Marshal.ThrowExceptionForHR(hr);
        try
        {
            var identity = new SecurityIdentifier(sid);
            if (!HasGrant(workspace, identity))
            {
                var acl = Directory.GetAccessControl(workspace);
                var original = new DirectorySecurity();
                original.SetSecurityDescriptorBinaryForm(acl.GetSecurityDescriptorBinaryForm(), AccessControlSections.Access);
                try
                {
                    acl.AddAccessRule(Grant(identity));
                    Directory.SetAccessControl(workspace, acl);
                    if (!HasGrant(workspace, identity)) throw new InvalidOperationException("workspace ACL grant verification failed");
                }
                catch (Exception grantError)
                {
                    try { CheckTreeForGrant(workspace); Directory.SetAccessControl(workspace, original); }
                    catch (Exception rollbackError) { throw new AggregateException("workspace grant failed and ACL rollback also failed", grantError, rollbackError); }
                    throw;
                }
            }
            if (!HasGrant(workspace, identity)) throw new InvalidOperationException("workspace ACL grant verification failed");
        }
        finally { Native.FreeSid(sid); }
    }

    internal static Snapshot Inspect(string workspace)
    {
        IntPtr sid = Derive(Moniker(workspace));
        try
        {
            var identity = new SecurityIdentifier(sid);
            var result = new Snapshot { Workspace = workspace, PackageSid = identity.Value,
                WorkspaceState = Directory.Exists(workspace) ? "present" : "missing", ProfileFolder = "absent", ProfileTemp = "absent" };
            if (result.WorkspaceState == "missing")
                result.Error = "workspace is missing; restore its original path before remove (a moved directory can retain the Package SID ACL)";
            if (result.WorkspaceState == "present")
            {
                try
                {
                    CheckDirectoryChain(workspace);
                    CheckTreeForGrant(workspace);
                    result.RootGrant = HasGrant(workspace, identity);
                    CheckNoOverlappingPackageGrant(workspace, identity);
                }
                catch (Exception error) { result.WorkspaceState = "unsafe"; result.Error = error.Message; }
            }
            try
            {
                string profile = ProfileFolder(identity);
                FileAttributes attributes;
                try { attributes = File.GetAttributes(profile); }
                catch (FileNotFoundException) { attributes = 0; }
                catch (DirectoryNotFoundException) { attributes = 0; }
                if ((attributes & FileAttributes.Directory) != 0)
                {
                    result.ProfileFolder = "present";
                    try
                    {
                        CheckDirectoryChain(profile);
                        CheckTreeForGrant(ProfileTreeRoot(profile));
                        string temp = Path.Combine(profile, "Temp");
                        if (Directory.Exists(temp)) { CheckDirectoryChain(temp); result.ProfileTemp = "present"; }
                        else if (File.Exists(temp)) { result.ProfileTemp = "unsafe"; result.Error = "profile Temp is not a directory"; }
                        else result.ProfileTemp = "missing";
                    }
                    catch (Exception error) { result.ProfileTemp = "unsafe"; result.Error = error.Message; }
                }
                else if (attributes != 0) { result.ProfileFolder = "unsafe"; result.Error = "profile path is not a directory"; }
            }
            catch (Exception error)
            {
                if (Marshal.GetHRForException(error) == unchecked((int)0x80070002)) result.ProfileFolder = "absent";
                else { result.ProfileFolder = "error"; result.Error = error.Message; }
            }
            result.Ready = result.WorkspaceState == "present" && result.ProfileFolder == "present" &&
                result.ProfileTemp != "unsafe" && result.RootGrant && result.Error == null;
            return result;
        }
        finally { Native.FreeSid(sid); }
    }

    internal static bool Status(string workspace, bool json = false)
    {
        Snapshot result = Inspect(workspace);
        if (json) Console.WriteLine(result.ToJson("status"));
        else Console.WriteLine("backend=appcontainer\npackageSid=" + result.PackageSid +
            "\nprofile=" + (result.ProfileFolder == "present").ToString().ToLowerInvariant() +
            "\nworkspaceGrant=" + result.RootGrant.ToString().ToLowerInvariant() +
            "\nworkspaceState=" + result.WorkspaceState + "\nprofileTemp=" + result.ProfileTemp +
            "\nnetworkCapabilities=none\nreadinessKind=static\nready=" + result.Ready.ToString().ToLowerInvariant() +
            (result.Error == null ? "" : "\nerror=" + result.Error));
        return result.Ready;
    }

    internal static bool Plan(string workspace, bool json)
    {
        Snapshot result = Inspect(workspace);
        if (json) Console.WriteLine(result.ToJson("plan"));
        else Console.WriteLine("workspace=" + result.Workspace + "\npackageSid=" + result.PackageSid +
            "\nsafe=" + result.Safe.ToString().ToLowerInvariant() +
            "\nwouldCreateProfile=" + result.WouldCreateProfile.ToString().ToLowerInvariant() +
            "\nwouldAddGrant=" + result.WouldAddGrant.ToString().ToLowerInvariant() +
            (result.Error == null ? "" : "\nerror=" + result.Error));
        return result.Safe;
    }

    internal static void Remove(string workspace)
    {
        string name = Moniker(workspace);
        IntPtr sid = Derive(name);
        try
        {
            var identity = new SecurityIdentifier(sid);
            // Finish every safety check before removing either part of the durable setup.
            CheckTreeForGrant(workspace);
            CheckRemovableTree(workspace, identity, true, true);
            if (ProfileExists(identity))
            {
                string profile = ProfileFolder(identity);
                CheckDirectoryChain(profile);
                CheckTreeForGrant(ProfileTreeRoot(profile));
            }
            int hr = Native.DeleteAppContainerProfile(name);
            if (hr != 0 && hr != unchecked((int)0x80070002)) Marshal.ThrowExceptionForHR(hr);
            var acl = Directory.GetAccessControl(workspace);
            acl.RemoveAccessRuleSpecific(Grant(identity));
            Directory.SetAccessControl(workspace, acl);
            if (HasGrant(workspace, identity)) throw new InvalidOperationException("workspace ACL revocation failed");
            CheckRemovableTree(workspace, identity, false, true);
        }
        finally { Native.FreeSid(sid); }
    }

    private static void CheckOwnPackageRules(FileSystemSecurity acl, string path, SecurityIdentifier identity, bool before, bool root)
    {
        foreach (FileSystemAccessRule rule in acl.GetAccessRules(true, true, typeof(SecurityIdentifier)))
        {
            if (!rule.IdentityReference.Equals(identity)) continue;
            if (before && root && IsExactGrant(rule, identity)) continue;
            if (before && !root && rule.IsInherited && rule.AccessControlType == AccessControlType.Allow &&
                rule.FileSystemRights == Grant(identity).FileSystemRights) continue;
            throw new InvalidOperationException("workspace has a residual AppContainer rule; restore inheritance or remove the unmanaged ACE before remove: " + path);
        }
    }

    private static void CheckRemovableTree(string path, SecurityIdentifier identity, bool before, bool root)
    {
        CheckOwnPackageRules(Directory.GetAccessControl(path), path, identity, before, root);
        foreach (string child in Directory.EnumerateFileSystemEntries(path))
        {
            FileAttributes attributes = File.GetAttributes(child);
            if ((attributes & FileAttributes.ReparsePoint) != 0) throw new ArgumentException("workspace tree contains a reparse point: " + child);
            if ((attributes & FileAttributes.Directory) != 0) CheckRemovableTree(child, identity, before, false);
            else CheckOwnPackageRules(File.GetAccessControl(child), child, identity, before, false);
        }
    }

    internal static IntPtr TokenInfo(IntPtr token, int type)
    {
        int size;
        Native.GetTokenInformation(token, type, IntPtr.Zero, 0, out size);
        if (size <= 0) Fail("GetTokenInformation(size)");
        IntPtr result = Marshal.AllocHGlobal(size);
        if (!Native.GetTokenInformation(token, type, result, size, out size))
        { Marshal.FreeHGlobal(result); Fail("GetTokenInformation"); }
        return result;
    }

    internal static void CheckChild(IntPtr process, SecurityIdentifier expected)
    {
        IntPtr token;
        if (!Native.OpenProcessToken(process, 8, out token)) Fail("OpenProcessToken(child)");
        try
        {
            IntPtr isContainer = TokenInfo(token, 29), package = IntPtr.Zero, capabilities = IntPtr.Zero;
            try
            {
                package = TokenInfo(token, 31);
                capabilities = TokenInfo(token, 30);
                if (Marshal.ReadInt32(isContainer) != 1 || !new SecurityIdentifier(Marshal.ReadIntPtr(package)).Equals(expected) || Marshal.ReadInt32(capabilities) != 0)
                    throw new InvalidOperationException("child token does not match the requested AppContainer with zero capabilities");
            }
            finally { Marshal.FreeHGlobal(isContainer); if (package != IntPtr.Zero) Marshal.FreeHGlobal(package); if (capabilities != IntPtr.Zero) Marshal.FreeHGlobal(capabilities); }
        }
        finally { Native.CloseHandle(token); }
    }

    internal static void Fail(string operation) { throw new Win32Exception(Marshal.GetLastWin32Error(), operation); }
}
