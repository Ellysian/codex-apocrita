using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using ApocritaAdapter;
public static class TransportTests
{
    static string root, harness, fixture, events; static int passed;
    static readonly object EventLock = new object();
    static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
    static void Report(string text) { lock(EventLock) { File.AppendAllText(events,DateTime.UtcNow.ToString("o")+" "+text+"\n",Utf8); Console.WriteLine(text); Console.Out.Flush(); } }
    static void Assert(bool value,string name) { if(!value) throw new Exception(name); passed++; Report("PASS "+name); }
    static string Line(string[] a) { return String.Join(" ",a.Select(NativeProcess.Quote)); }
    static Process Spawn(string[] args) {
        if(!File.Exists(harness)) throw new Exception("NativeHarness file missing; stop without rebuilding");
        var p=new Process { StartInfo=new ProcessStartInfo(harness,Line(args)) { UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true,StandardOutputEncoding=Utf8,StandardErrorEncoding=Utf8 } };
        p.Start(); return p;
    }
    static void Cleanup(Process p) { if(p==null) return; if(!p.HasExited) p.Kill(); if(!p.WaitForExit(5000)) throw new Exception("owned harness cleanup deadline"); }
    sealed class Result { public byte[] Output; public string Error; public int Code; }
    static void FailureDetail(string name,Result result) {
        // Only local synthetic fixture failures reach this method. Never log
        // production streams or more than 64 bytes from either fixture stream.
        byte[] error=Utf8.GetBytes(result.Error);
        Report("FAILURE_DETAIL case="+name+" exit="+result.Code+" stdout_bytes="+result.Output.Length+
            " stdout_head64_hex="+BitConverter.ToString(result.Output.Take(64).ToArray()).Replace("-","")+
            " stderr_bytes="+error.Length+" stderr_head64_hex="+BitConverter.ToString(error.Take(64).ToArray()).Replace("-",""));
    }
    static Result Run(string[] args,byte[] input) {
        using(var p=Spawn(args)) { try {
            var output=Task.Run(delegate { using(var m=new MemoryStream()) { p.StandardOutput.BaseStream.CopyTo(m); return m.ToArray(); } });
            var error=Task.Run(delegate { return p.StandardError.ReadToEnd(); });
            var writer=Task.Run(delegate { p.StandardInput.BaseStream.Write(input,0,input.Length); p.StandardInput.BaseStream.Close(); });
            if(!p.WaitForExit(15000)) throw new Exception("transport fixture deadline");
            if(!Task.WaitAll(new Task[]{output,error,writer},5000)) throw new Exception("fixture pipe-drain deadline");
            return new Result { Output=output.Result,Error=error.Result,Code=p.ExitCode };
        } finally { Cleanup(p); } }
    }
    static string ReadLine(Process p) {
        var line=Task.Run(delegate { var data=new MemoryStream(); while(data.Length<128) { int value=p.StandardOutput.BaseStream.ReadByte(); if(value<0) throw new Exception("fixture exited before PID record"); if(value==10) return Encoding.ASCII.GetString(data.ToArray()); data.WriteByte((byte)value); } throw new Exception("PID record exceeded bound"); });
        if(!line.Wait(5000)) throw new Exception("fixture PID record deadline"); return line.Result;
    }
    static int ReadPid(Process p) { string line=ReadLine(p); int pid; if(!line.StartsWith("PID ",StringComparison.Ordinal)||!Int32.TryParse(line.Substring(4),out pid)||pid<=0) throw new Exception("malformed fixture PID record"); return pid; }
    static byte[] ReadBytes(Process p,int count) {
        var task=Task.Run(delegate { byte[] data=new byte[count]; int offset=0; while(offset<count) { int size=p.StandardOutput.BaseStream.Read(data,offset,count-offset); if(size==0) throw new Exception("fixture stream ended early"); offset+=size; } return data; });
        if(!task.Wait(5000)) throw new Exception("fixture stream read deadline"); return task.Result;
    }
    static string[] DecodeArguments(byte[] output) {
        using(var reader=new StringReader(Utf8.GetString(output))) {
            string header=reader.ReadLine(); int count; if(header==null||!header.StartsWith("ARGV64 ")||!Int32.TryParse(header.Substring(7),out count)||count<0||count>100) throw new Exception("invalid argv fixture header");
            var args=new string[count]; for(int i=0;i<count;i++) { string encoded=reader.ReadLine(); if(encoded==null) throw new Exception("missing argv fixture record"); args[i]=Utf8.GetString(Convert.FromBase64String(encoded)); }
            if(reader.ReadToEnd().Length!=0) throw new Exception("trailing argv fixture output"); return args;
        }
    }
    static void Streaming(string[] prefix,string name) {
        using(var p=Spawn(prefix.Concat(new[]{"echo"}).ToArray())) { try {
            byte[] first=Utf8.GetBytes("early-output-\u4E2D\u6587\0\r\n"); var error=Task.Run(delegate { return p.StandardError.ReadToEnd(); });
            p.StandardInput.BaseStream.Write(first,0,first.Length); p.StandardInput.BaseStream.Flush();
            Assert(ReadBytes(p,first.Length).SequenceEqual(first),name+" output before EOF"); p.StandardInput.BaseStream.Close();
            Assert(p.WaitForExit(5000)&&p.ExitCode==0,name+" EOF exit"); Assert(error.Wait(5000)&&error.Result.Replace("\r\n","\n")=="STDERR_ONLY\n",name+" stderr separation");
        } finally { Cleanup(p); } }
    }
    static void Exercise(string[] prefix,string name) {
        Report("CASE_BEGIN "+name+" byte-transport");
        // Escaped code points preserve Unicode and surrogate-pair fixture data.
        string[] weird={"","a b","\u4E2D\u6587\uD83D\uDE80","\"quoted\"","ends\\","a\\\"b","line1\nline2\r\n","$(do-not-execute); & | > < ` %PATH%","--flag","-oProxyCommand=bad"};
        var r=Run(prefix.Concat(new[]{"argv"}).Concat(weird).ToArray(),new byte[0]);
        try { Assert(r.Code==0&&DecodeArguments(r.Output).SequenceEqual(weird),name+" argument boundaries and Unicode"); }
        catch { FailureDetail(name+"-argv",r); throw; }
        foreach(int size in new[]{0,1,8193,2*1024*1024}) { byte[] data=new byte[size]; new Random(17+size).NextBytes(data); r=Run(prefix.Concat(new[]{"echo","23"}).ToArray(),data); if(r.Code!=23||!r.Output.SequenceEqual(data)||r.Error.Replace("\r\n","\n")!="STDERR_ONLY\n") FailureDetail(name+"-binary-"+size,r); Assert(r.Code==23&&r.Output.SequenceEqual(data),name+" binary stream "+size+" and nonzero exit"); Assert(r.Error.Replace("\r\n","\n")=="STDERR_ONLY\n",name+" independent stderr "+size); }
        Streaming(prefix,name);
        ConcurrentStreams(prefix,name);
    }
    static void ConcurrentStreams(string[] prefix,string name) {
        var connections=new Process[3];
        try {
            // Each echo fixture emits readiness before waiting for stdin. Keep
            // stdin open until all three fixtures have acknowledged readiness,
            // so simultaneous liveness is measured rather than inferred from
            // Task.Run scheduling or three successful serial completions.
            for(int i=0;i<3;i++) connections[i]=Spawn(prefix.Concat(new[]{"echo"}).ToArray());
            for(int i=0;i<3;i++) {
                int at=i; var ready=Task.Run(delegate { return connections[at].StandardError.ReadLine(); });
                if(!ready.Wait(5000)||ready.Result!="STDERR_ONLY") throw new Exception("concurrent fixture readiness failed");
            }
            Assert(connections.All(p=>!p.HasExited),name+" three live fixture streams overlap before EOF");
            Report("OVERLAPPING_STREAMS platform="+name+" harness_pids="+String.Join(",",connections.Select(p=>p.Id.ToString())));
            var output=new Task<byte[]>[3]; var errors=new Task<string>[3]; var writers=new Task[3]; var expected=new byte[3][];
            for(int i=0;i<3;i++) {
                int at=i; expected[at]=new byte[131072+at]; new Random(at).NextBytes(expected[at]);
                output[at]=Task.Run(delegate { using(var memory=new MemoryStream()) { connections[at].StandardOutput.BaseStream.CopyTo(memory); return memory.ToArray(); } });
                errors[at]=Task.Run(delegate { return connections[at].StandardError.ReadToEnd(); });
                writers[at]=Task.Run(delegate { connections[at].StandardInput.BaseStream.Write(expected[at],0,expected[at].Length); connections[at].StandardInput.BaseStream.Close(); });
            }
            foreach(var process in connections) if(!process.WaitForExit(15000)) throw new Exception("parallel fixture exit deadline");
            var all=output.Cast<Task>().Concat(errors.Cast<Task>()).Concat(writers).ToArray();
            if(!Task.WaitAll(all,5000)) throw new Exception("parallel fixture pipe-drain deadline");
            bool equal=true;
            for(int i=0;i<3;i++) {
                bool item=connections[i].ExitCode==0&&output[i].Result.SequenceEqual(expected[i])&&errors[i].Result.Length==0;
                if(!item) FailureDetail(name+"-parallel-"+i,new Result {Code=connections[i].ExitCode,Output=output[i].Result,Error=errors[i].Result});
                equal&=item;
            }
            Assert(equal,name+" three simultaneous streams");
        } finally {
            foreach(var process in connections) if(process!=null) { try { Cleanup(process); } finally { process.Dispose(); } }
        }
    }
    static bool Alive(int pid) { try { using(var p=Process.GetProcessById(pid)) return !p.HasExited; } catch(ArgumentException) {return false;} }
    static bool WindowsGone(params int[] pids) { var watch=Stopwatch.StartNew(); do { if(pids.All(pid=>!Alive(pid))) return true; Thread.Sleep(50); } while(watch.ElapsedMilliseconds<5000); return false; }
    static void VerifySurvivor(Process p,string name) { byte[] marker=Utf8.GetBytes("survivor-roundtrip-\u4E2D\u6587\n"); p.StandardInput.BaseStream.Write(marker,0,marker.Length); p.StandardInput.BaseStream.Flush(); Assert(ReadBytes(p,marker.Length).SequenceEqual(marker),name+" other connection exchanges bytes after cancellation"); }
    static void WindowsCancellation() {
        Report("CASE_BEGIN Windows cancellation"); Process first=null,second=null;
        try {
            first=Spawn(new[]{fixture,"tree"}); second=Spawn(new[]{fixture,"duplex"});
            string[] record=ReadLine(first).Split(' '); int parent,child;
            if(record.Length!=3||record[0]!="TREE"||!Int32.TryParse(record[1],out parent)||!Int32.TryParse(record[2],out child)) throw new Exception("malformed fixture tree record");
            int survivor=ReadPid(second); Report("WINDOWS_CANCEL parent_pid="+parent+" grandchild_pid="+child+" survivor_pid="+survivor); Cleanup(first); Assert(WindowsGone(parent,child),"cancel kills Windows child and grandchild"); VerifySurvivor(second,"Windows"); Cleanup(second); Assert(WindowsGone(survivor),"Windows second connection cleanup");
        } finally { try { Cleanup(first); } finally { Cleanup(second); if(first!=null) first.Dispose(); if(second!=null) second.Dispose(); } }
    }
    public static int Main(string[] args) {
        try {
            // .NET Framework uses Console.InputEncoding for redirected stdin
            // and AutoFlush can emit its preamble before the first write. Keep
            // synthetic input byte-exact, including the empty-input case.
            Console.InputEncoding = Utf8;
            if(args.Length!=2) throw new Exception("test root and event path required"); root=Path.GetFullPath(args[0]); events=Path.GetFullPath(args[1]); passed=0; harness=Path.Combine(root,"tests","bin","NativeHarness.exe"); fixture=Path.Combine(root,"tests","bin","StreamFixture.exe");
            Report("MAIN_ENTER runtime="+Environment.Version+" pid="+Process.GetCurrentProcess().Id); Exercise(new[]{fixture},"Windows"); WindowsCancellation();
Report("TRANSPORT_TESTS_PASS count="+passed); return 0;
        } catch(Exception e) { string text="FAIL "+e.GetType().Name+" "+e.Message; if(events!=null) Report(text); else Console.Error.WriteLine(text); return 1; }
    }
}
