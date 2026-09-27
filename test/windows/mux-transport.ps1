#requires -Version 7.0
param([string]$Bin="$PSScriptRoot/../../zig-out/bin")
$ErrorActionPreference='Stop'
$Bin=(Resolve-Path $Bin).Path
$dir=Join-Path $env:TEMP ('yuurei-mux-transport-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory "$dir/bin" -Force | Out-Null
Copy-Item "$Bin/yuurei-mux.exe" "$dir/bin/yuurei-mux.exe"
# A test client in the isolated installation is deliberately named ghostty.exe
# so framing tests pass peer authentication. The identical intruder.exe must fail.
@'
using System; using System.IO; using System.IO.Pipes; using System.Text; using System.Threading;
class Probe {
 static byte[] Header(int op,int length) {
  byte[] h=new byte[24];Encoding.ASCII.GetBytes("YMUX").CopyTo(h,0);
  h[4]=4;h[6]=(byte)op;BitConverter.GetBytes(length).CopyTo(h,8);return h;
 }
 static byte[] Read(NamedPipeClientStream p,int n) {
  byte[] b=new byte[n];int at=0;
  while(at<n){var t=p.ReadAsync(b,at,n-at);if(!t.Wait(7000))throw new Exception("Read deadline exceeded");if(t.Result==0)throw new EndOfStreamException();at+=t.Result;}return b;
 }
 static void Send(NamedPipeClientStream p,byte[] b,bool fragmented) {
  if(!fragmented){p.Write(b,0,b.Length);return;}
  foreach(byte v in b){p.WriteByte(v);Thread.Sleep(2);}
 }
 static void Hello(NamedPipeClientStream p,string version,bool fragmented) {
  byte[] b=Encoding.UTF8.GetBytes(version);Send(p,Header(6,b.Length),fragmented);Send(p,b,fragmented);
  byte[] h=Read(p,24);if(h[6]!=6||BitConverter.ToInt32(h,8)!=b.Length)throw new Exception("Bad hello reply");
  if(Encoding.UTF8.GetString(Read(p,b.Length))!=version)throw new Exception("Bad build reply");
 }
 static void Rejected(NamedPipeClientStream p,Action send) {
  try {send();}catch(IOException){return;}
  try {Read(p,1);}catch(IOException){return;}
  throw new Exception("Malformed request was accepted");
 }
 static int Main(string[] a) {
  try {
   using(var p=new NamedPipeClientStream(".",a[0],PipeDirection.InOut,PipeOptions.Asynchronous)){
    p.Connect(5000);string mode=a[2];
    if(mode=="fragmented"){
     Hello(p,a[1],true);Send(p,Header(1,0),true);byte[] h=Read(p,24);int n=BitConverter.ToInt32(h,8);
     if(h[6]!=1||n<1||n>4096||!Encoding.UTF8.GetString(Read(p,n)).Contains("shell_pid"))throw new Exception("Bad status");
    }else if(mode=="posthello-stall"){
     Hello(p,a[1],false);Rejected(p,()=>p.WriteByte((byte)'Y'));
    }else if(mode=="badbuild"){
     Rejected(p,()=>{byte[] b=Encoding.ASCII.GetBytes("invalid-build");Send(p,Header(6,b.Length),false);Send(p,b,false);});
    }else if(mode=="stall-header"){
     Rejected(p,()=>p.WriteByte((byte)'Y'));
    }else if(mode=="stall-payload"){
     Rejected(p,()=>Send(p,Header(6,32),false));
    }else{
     byte[] h=Header(6,0);
     switch(mode){
      case "magic":h[0]=0;break;
      case "version":h[4]=255;break;
      case "flags":h[12]=1;break;
      case "operation":h[6]=255;break;
      case "oversize":h=Header(6,65537);break;
      case "prehello":h=Header(3,0);break;
      case "unauthorized":break;
      default:throw new Exception("Unknown probe");
     }
     Rejected(p,()=>Send(p,h,false));
    }
   }
   Console.WriteLine("PASS "+a[2]);return 0;
  }catch(Exception e){Console.Error.WriteLine(e);return 1;}
 }
}
'@ | Set-Content "$dir/probe.cs"
& "$env:WINDIR/Microsoft.NET/Framework64/v4.0.30319/csc.exe" /nologo /target:exe "/out:$dir\bin\ghostty.exe" "$dir\probe.cs"
if($LASTEXITCODE -ne 0){throw 'Probe compilation failed'}
Copy-Item "$dir/bin/ghostty.exe" "$dir/bin/intruder.exe"
$name='transport-'+[guid]::NewGuid().ToString('N')
$broker=Start-Process "$dir/bin/yuurei-mux.exe" -ArgumentList @('serve',$name,'cmd.exe','/D','/Q','/K') -PassThru -WindowStyle Hidden -Environment @{LOCALAPPDATA=$dir} -RedirectStandardError "$dir/broker.log"
try{
 $record=$null
 for($i=0;$i -lt 100 -and !$record;$i++){
  $record=Get-ChildItem "$dir/ghostty/mux" -Filter "$name.json" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  if(!$record){Start-Sleep -Milliseconds 50}
 }
 if(!$record){throw 'Broker registration missing'}
 $entry=Get-Content $record.FullName -Raw | ConvertFrom-Json
 $pipe='LOCAL\yuurei-mux-experimental-'+$record.Directory.Name+'-'+$name
 $baseline=Get-Process -Id $broker.Id
 $handles=$baseline.HandleCount
 foreach($mode in @('fragmented','magic','version','flags','operation','oversize','prehello','badbuild','stall-header','stall-payload','posthello-stall','unauthorized','fragmented')){
  $exe=if($mode -eq 'unauthorized'){'intruder.exe'}else{'ghostty.exe'}
  & "$dir/bin/$exe" $pipe $entry.version $mode
  if($LASTEXITCODE -ne 0){throw "Probe failed: $mode"}
  Start-Sleep -Milliseconds 50
  & "$dir/bin/yuurei-mux.exe" status $name | Out-Null
  if($LASTEXITCODE -ne 0){throw "Broker did not recover after $mode"}
 }
 $broker.Refresh()
 if($broker.HandleCount -gt $handles+3){throw 'Malformed clients leaked broker handles'}
 Write-Output "PASS: fragmented framing, bounds, authentication, stalled transfers, recovery, stable handles. Artifacts: $dir"
}finally{
 if(!$broker.HasExited){& "$dir/bin/yuurei-mux.exe" stop $name | Out-Null;if(!$broker.WaitForExit(5000)){$broker.Kill();$broker.WaitForExit()}}
 $broker.Dispose()
}
