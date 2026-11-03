param([string]$SandboxExe = (Join-Path (Split-Path -Parent $PSScriptRoot) 'bank-sandbox.exe'))
$ErrorActionPreference = 'Stop'
$module = Split-Path -Parent $PSScriptRoot
$launcher = Join-Path $module 'launch.ps1'
if (-not (Test-Path -LiteralPath $launcher)) { throw 'FAIL: secure OpenCode launcher is missing' }
$root = Join-Path $PSScriptRoot ('launcher-runs\' + [guid]::NewGuid().ToString('N'))
$workspace = Join-Path $root 'workspace'
$source = Join-Path $root 'source.json'
$fakeSource = Join-Path $root 'fake-opencode.cs'
$fakeExe = Join-Path $root 'fake-opencode.exe'
$marker = Join-Path $root 'run.marker'
$output = Join-Path $root 'events.jsonl'
$savedState = $env:BANK_FAKE_PLUGIN_STATE
$savedMarker = $env:BANK_FAKE_RUN_MARKER
$savedProfile = $env:USERPROFILE
$savedHome = $env:HOME
try {
    New-Item -ItemType Directory -Path $workspace -Force | Out-Null
    Set-Content -LiteralPath $source -Encoding UTF8 -Value '{"model":"fake/model","providers":{"fake":{"settings":{"apiKey":"SYNTHETIC"}}},"plugins":["unsafe-old-plugin"],"mcp":{"unsafe":{}},"agents":{"unsafe":{}}}'
    Set-Content -LiteralPath $fakeSource -Encoding Ascii -Value @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Diagnostics;
using System.Collections.Generic;
using System.Web.Script.Serialization;
class Fake {
 static string Value(string[] args,string key) {int i=Array.IndexOf(args,key);return i<0?null:args[i+1];}
 static int Main(string[] args) {
  Console.OutputEncoding = new UTF8Encoding(false);
  if(Array.IndexOf(args,"serve")>=0){
   int port=int.Parse(Value(args,"--port"));var listener=new TcpListener(IPAddress.Loopback,port);listener.Start();
   for(;;) using(var client=listener.AcceptTcpClient()) using(var stream=client.GetStream()) {
    var reader=new StreamReader(stream,Encoding.ASCII,false,1024,true);string request=reader.ReadLine()??"";string auth="";string line;
    while(!string.IsNullOrEmpty(line=reader.ReadLine())) if(line.StartsWith("Authorization:",StringComparison.OrdinalIgnoreCase))auth=line.Substring(14).Trim();
    string expected="Basic "+Convert.ToBase64String(Encoding.UTF8.GetBytes("opencode:"+Environment.GetEnvironmentVariable("OPENCODE_PASSWORD")));
    string state=Environment.GetEnvironmentVariable("BANK_FAKE_PLUGIN_STATE")??"failed";
    string body=request.Contains("/api/info")?"{\"version\":\"fake\",\"pid\":"+Process.GetCurrentProcess().Id+"}":"{\"data\":[{\"id\":\"opencode-v2-bank-appcontainer\",\"state\":{\"status\":\""+state+"\"}}]}";
    bool ok=auth==expected; if(!ok)body="{}"; byte[] bytes=Encoding.UTF8.GetBytes(body);
    byte[] header=Encoding.ASCII.GetBytes("HTTP/1.1 "+(ok?"200 OK":"401 Unauthorized")+"\r\nContent-Type: application/json\r\nContent-Length: "+bytes.Length+"\r\nConnection: close\r\n\r\n");stream.Write(header,0,header.Length);stream.Write(bytes,0,bytes.Length);
   }
  }
  if(Array.IndexOf(args,"run")>=0){
   foreach(string key in new[]{"OPENCODE_CONFIG_PROJECT_DISABLE","OPENCODE_DISABLE_CLAUDE_CODE","BANK_SANDBOX_LAUNCHER"})if(Environment.GetEnvironmentVariable(key)!="1")return 41;
   var config=File.ReadAllText(Path.Combine(Environment.GetEnvironmentVariable("OPENCODE_CONFIG_DIR"),"bocomcode.json"));
   var json=new JavaScriptSerializer();var data=(Dictionary<string,object>)json.DeserializeObject(config);
   if(data.ContainsKey("mcp")||data.ContainsKey("agents")||config.Contains("unsafe-old-plugin"))return 42;
   File.WriteAllText(Environment.GetEnvironmentVariable("BANK_FAKE_RUN_MARKER"),"RUN");
   Console.WriteLine(json.Serialize(new{cwd=Environment.CurrentDirectory,privateHome=Environment.GetEnvironmentVariable("USERPROFILE"),message=args[args.Length-1],model=Value(args,"--model")}));return 0;
  }
  return 43;
 }
}
'@
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:exe /platform:x64 /reference:System.Web.Extensions.dll ("/out:" + $fakeExe) $fakeSource
    if ($LASTEXITCODE -ne 0) { throw 'fixture compile failed' }
    $env:BANK_FAKE_RUN_MARKER = $marker
    $env:BANK_FAKE_PLUGIN_STATE = 'active'
    $originalHash=(Get-FileHash -LiteralPath $fakeExe -Algorithm SHA256).Hash
    $originalAcl=Get-Acl -LiteralPath $fakeExe
    try {
        $changedAcl=Get-Acl -LiteralPath $fakeExe
        $allPackages=[Security.Principal.SecurityIdentifier]::new('S-1-15-2-1')
        $changedAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($allPackages,[Security.AccessControl.FileSystemRights]::Modify,[Security.AccessControl.AccessControlType]::Allow))
        Set-Acl -LiteralPath $fakeExe -AclObject $changedAcl
        $failed=$false
        try { & $launcher -Workspace $workspace -SandboxExe $SandboxExe -OpenCodeExe $fakeExe -Model 'fake/model' -Message 'must not run' -OutputLog $output -SourceConfig $source -StartupTimeoutSeconds 5 }
        catch { $failed=$true }
        if (-not $failed -or (Test-Path -LiteralPath $marker) -or (Get-FileHash -LiteralPath $fakeExe -Algorithm SHA256).Hash -ne $originalHash) { throw 'FAIL: trusted executable write ACE did not block model start without content changes' }
        Write-Output 'PASS: writable trusted executable blocks startup without changing file content'
    }
    finally { Set-Acl -LiteralPath $fakeExe -AclObject $originalAcl }
    $env:BANK_FAKE_PLUGIN_STATE = 'failed'
    $failed = $false
    try { & $launcher -Workspace $workspace -SandboxExe $SandboxExe -OpenCodeExe $fakeExe -Model 'fake/model' -Message 'must not run' -OutputLog $output -SourceConfig $source -StartupTimeoutSeconds 5 }
    catch { $failed = $true }
    if (-not $failed -or (Test-Path -LiteralPath $marker)) { throw 'FAIL: inactive plugin allowed the model client to start' }
    Write-Output 'PASS: failed plugin prevents model client launch'
    $env:BANK_FAKE_PLUGIN_STATE = 'active'
    $message = "quoted `"value`" with space and trailing\"
    & $launcher -Workspace $workspace -SandboxExe $SandboxExe -OpenCodeExe $fakeExe -Model 'fake/model' -Message $message -OutputLog $output -SourceConfig $source -StartupTimeoutSeconds 10
    $result = Get-Content -LiteralPath $output -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($result.message -ne $message -or $result.cwd -ne (Join-Path $result.privateHome 'control') -or $result.model -ne 'fake/model') { throw ('FAIL: native argv or trusted control cwd was not preserved: actual='+($result | ConvertTo-Json -Compress)+'; expected='+$message) }
    if ($env:USERPROFILE -ne $savedProfile -or $env:HOME -ne $savedHome) { throw 'FAIL: launcher changed parent environment' }
    Write-Output 'PASS: active plugin runs client in trusted control with isolated config, exact argv and unchanged parent environment'
    if (-not $result.privateHome -or (Test-Path -LiteralPath $result.privateHome)) { throw 'FAIL: temporary home was not removed' }
    Write-Output 'PASS: launcher removed sensitive temporary home'
}
finally {
    $env:BANK_FAKE_PLUGIN_STATE = $savedState
    $env:BANK_FAKE_RUN_MARKER = $savedMarker
    if (Test-Path -LiteralPath $workspace) { & $SandboxExe remove --workspace $workspace | Out-Null; if($LASTEXITCODE -ne 0){throw 'fixture sandbox cleanup failed'} }
    $base=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'launcher-runs')) + '\'
    if (-not [IO.Path]::GetFullPath($root).StartsWith($base,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup' }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
