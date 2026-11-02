using System;
using System.Text;

internal sealed class Snapshot
{
    internal string Workspace, PackageSid, WorkspaceState, ProfileFolder, ProfileTemp, Error;
    internal bool RootGrant, Ready;
    internal bool Safe { get { return WorkspaceState == "present" && Error == null &&
        (ProfileFolder == "present" || ProfileFolder == "absent"); } }
    internal bool WouldCreateProfile { get { return ProfileFolder == "absent"; } }
    internal bool WouldAddGrant { get { return WorkspaceState == "present" && !RootGrant; } }

    private static string Quote(string value)
    {
        var output = new StringBuilder("\"");
        foreach (char c in value ?? "")
        {
            if (c == '"' || c == '\\') output.Append('\\').Append(c);
            else if (c == '\n') output.Append("\\n");
            else if (c == '\r') output.Append("\\r");
            else if (c == '\t') output.Append("\\t");
            else if (c < 32) output.Append("\\u").Append(((int)c).ToString("x4"));
            else output.Append(c);
        }
        return output.Append('"').ToString();
    }

    internal string ToJson(string action)
    {
        return "{" +
            "\"action\":" + Quote(action) + "," +
            "\"backend\":\"appcontainer\"," +
            "\"workspace\":" + Quote(Workspace) + "," +
            "\"packageSid\":" + Quote(PackageSid) + "," +
            "\"workspaceState\":" + Quote(WorkspaceState) + "," +
            "\"profileFolder\":" + Quote(ProfileFolder) + "," +
            "\"profileTemp\":" + Quote(ProfileTemp) + "," +
            "\"rootGrant\":" + RootGrant.ToString().ToLowerInvariant() + "," +
            "\"networkCapabilities\":\"none\"," +
            "\"readinessKind\":\"static\"," +
            "\"ready\":" + Ready.ToString().ToLowerInvariant() + "," +
            "\"safe\":" + Safe.ToString().ToLowerInvariant() + "," +
            "\"wouldCreateProfile\":" + WouldCreateProfile.ToString().ToLowerInvariant() + "," +
            "\"wouldAddGrant\":" + WouldAddGrant.ToString().ToLowerInvariant() + "," +
            "\"error\":" + (Error == null ? "null" : Quote(Error)) + "}";
    }
}
