using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Apocrita.PackageActivation
{
    [ComImport, Guid("2E941141-7F97-4756-BA1D-9DECDE894A3D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IApplicationActivationManager
    {
        [PreserveSig] int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string appId,
            [MarshalAs(UnmanagedType.LPWStr)] string arguments, uint options, out uint processId);
        [PreserveSig] int ActivateForFile([MarshalAs(UnmanagedType.LPWStr)] string appId, IntPtr items,
            [MarshalAs(UnmanagedType.LPWStr)] string verb, out uint processId);
        [PreserveSig] int ActivateForProtocol([MarshalAs(UnmanagedType.LPWStr)] string appId, IntPtr items, out uint processId);
    }
    [ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
    class ApplicationActivationManager { }

    public sealed class ActivationResult
    {
        public int HResult;
        public uint ProcessId;
        public string ProcessStartUtc;
        public string Executable;
        public string PackageFullName;
        public int PackageQueryError;
        public long DurationMilliseconds;
    }

    public static class Desktop
    {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
        private static extern int GetPackageFullName(IntPtr process, ref uint size, StringBuilder name);

        // Standard package activation, not a debug token or a copied executable.
        public static ActivationResult Activate()
        {
            ActivationResult result=null; Exception failure=null;
            var thread = new Thread(() =>
            {
                IApplicationActivationManager manager=null;
                try
                {
                    manager=(IApplicationActivationManager)new ApplicationActivationManager();
                    var clock=Stopwatch.StartNew(); uint pid;
                    int hr=manager.ActivateApplication("OpenAI.Codex_2p2nqsd0c76g0!App", null, 0, out pid);
                    result=new ActivationResult {HResult=hr,ProcessId=pid,DurationMilliseconds=clock.ElapsedMilliseconds};
                    if(hr<0 || pid==0) return;
                    using(var process=Process.GetProcessById((int)pid))
                    {
                        result.ProcessStartUtc=process.StartTime.ToUniversalTime().ToString("o");
                        result.Executable=process.MainModule.FileName;
                        uint size=0;
                        result.PackageQueryError=GetPackageFullName(process.Handle,ref size,null);
                        if(result.PackageQueryError==122 && size>0 && size<32768)
                        {
                            var name=new StringBuilder((int)size);
                            result.PackageQueryError=GetPackageFullName(process.Handle,ref size,name);
                            if(result.PackageQueryError==0) result.PackageFullName=name.ToString();
                        }
                    }
                }
                catch(Exception e) {failure=e;}
                finally {if(manager!=null) Marshal.FinalReleaseComObject(manager);}
            });
            thread.SetApartmentState(ApartmentState.STA); thread.Start(); thread.Join();
            if(failure!=null) throw new InvalidOperationException("Official Windows package activation did not complete.",failure);
            return result;
        }
    }
}
