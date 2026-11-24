using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class Hcs
{
    const string Dll = "computecore.dll";

    [DllImport(Dll)] static extern IntPtr HcsCreateOperation(IntPtr context, IntPtr callback);
    [DllImport(Dll)] static extern int HcsWaitForOperationResult(IntPtr op, uint timeoutMs, out IntPtr resultDocument);
    [DllImport(Dll)] static extern void HcsCloseOperation(IntPtr op);
    [DllImport(Dll, CharSet = CharSet.Unicode)] static extern int HcsCreateComputeSystem(string id, string configuration, IntPtr op, IntPtr securityDescriptor, out IntPtr computeSystem);
    [DllImport(Dll, CharSet = CharSet.Unicode)] static extern int HcsOpenComputeSystem(string id, uint requestedAccess, out IntPtr computeSystem);
    [DllImport(Dll, CharSet = CharSet.Unicode)] static extern int HcsStartComputeSystem(IntPtr cs, IntPtr op, string options);
    [DllImport(Dll, CharSet = CharSet.Unicode)] static extern int HcsShutDownComputeSystem(IntPtr cs, IntPtr op, string options);
    [DllImport(Dll, CharSet = CharSet.Unicode)] static extern int HcsTerminateComputeSystem(IntPtr cs, IntPtr op, string options);
    [DllImport(Dll, CharSet = CharSet.Unicode)] static extern int HcsModifyComputeSystem(IntPtr cs, IntPtr op, string configuration, IntPtr identity);
    [DllImport(Dll, CharSet = CharSet.Unicode)] static extern int HcsGetComputeSystemProperties(IntPtr cs, IntPtr op, string propertyQuery);
    [DllImport(Dll, CharSet = CharSet.Unicode)] static extern int HcsEnumerateComputeSystems(string query, IntPtr op);
    [DllImport(Dll, CharSet = CharSet.Unicode)] static extern int HcsGetServiceProperties(string propertyQuery, out IntPtr result);
    [DllImport(Dll)] static extern void HcsCloseComputeSystem(IntPtr cs);
    [DllImport(Dll, CharSet = CharSet.Unicode)] public static extern int HcsGrantVmAccess(string vmId, string filePath);
    [DllImport(Dll, CharSet = CharSet.Unicode)] public static extern int HcsRevokeVmAccess(string vmId, string filePath);
    [DllImport(Dll, CharSet = CharSet.Unicode)] public static extern int HcsCreateEmptyGuestStateFile(string path);
    [DllImport(Dll, CharSet = CharSet.Unicode)] public static extern int HcsCreateEmptyRuntimeStateFile(string path);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);

    public class Result { public int Hr; public string Doc; public override string ToString() { return string.Format("0x{0:X8} {1}", Hr, Doc); } }

    static string Take(IntPtr p) { if (p == IntPtr.Zero) return null; var s = Marshal.PtrToStringUni(p); LocalFree(p); return s; }

    static Result Run(Func<IntPtr, int> call, uint timeoutMs)
    {
        var op = HcsCreateOperation(IntPtr.Zero, IntPtr.Zero);
        if (op == IntPtr.Zero) return new Result { Hr = unchecked((int)0x8007000E) };
        try
        {
            int hr = call(op);
            IntPtr doc;
            int wait = HcsWaitForOperationResult(op, timeoutMs, out doc);
            return new Result { Hr = hr < 0 ? hr : wait, Doc = Take(doc) };
        }
        finally { HcsCloseOperation(op); }
    }

    public static Result Create(string id, string json, out IntPtr cs, uint timeoutMs = 60000)
    {
        IntPtr h = IntPtr.Zero;
        var r = Run(op => HcsCreateComputeSystem(id, json, op, IntPtr.Zero, out h), timeoutMs);
        cs = h;
        return r;
    }

    public static Result Open(string id, out IntPtr cs) { int hr = HcsOpenComputeSystem(id, 0x10000000, out cs); return new Result { Hr = hr }; }
    public static Result Start(IntPtr cs, uint timeoutMs = 120000) { return Run(op => HcsStartComputeSystem(cs, op, null), timeoutMs); }
    public static Result ShutDown(IntPtr cs, uint timeoutMs = 60000) { return Run(op => HcsShutDownComputeSystem(cs, op, null), timeoutMs); }
    public static Result Terminate(IntPtr cs, uint timeoutMs = 60000) { return Run(op => HcsTerminateComputeSystem(cs, op, null), timeoutMs); }
    public static Result Modify(IntPtr cs, string json, uint timeoutMs = 60000) { return Run(op => HcsModifyComputeSystem(cs, op, json, IntPtr.Zero), timeoutMs); }
    public static Result Properties(IntPtr cs, string query = null, uint timeoutMs = 10000) { return Run(op => HcsGetComputeSystemProperties(cs, op, query), timeoutMs); }
    public static Result Enumerate(string query = null) { return Run(op => HcsEnumerateComputeSystems(query, op), 10000); }
    public static Result ServiceProperties(string query) { IntPtr p; int hr = HcsGetServiceProperties(query, out p); return new Result { Hr = hr, Doc = Take(p) }; }
    public static void Close(IntPtr cs) { if (cs != IntPtr.Zero) HcsCloseComputeSystem(cs); }

    [DllImport("computenetwork.dll", CharSet = CharSet.Unicode)] static extern int HcnCreateNetwork(ref Guid id, string settings, out IntPtr network, out IntPtr errorRecord);
    [DllImport("computenetwork.dll", CharSet = CharSet.Unicode)] static extern int HcnOpenNetwork(ref Guid id, out IntPtr network, out IntPtr errorRecord);
    [DllImport("computenetwork.dll")] static extern int HcnCloseNetwork(IntPtr network);
    [DllImport("computenetwork.dll", CharSet = CharSet.Unicode)] static extern int HcnDeleteNetwork(ref Guid id, out IntPtr errorRecord);
    [DllImport("computenetwork.dll", CharSet = CharSet.Unicode)] static extern int HcnCreateEndpoint(IntPtr network, ref Guid id, string settings, out IntPtr endpoint, out IntPtr errorRecord);
    [DllImport("computenetwork.dll")] static extern int HcnCloseEndpoint(IntPtr endpoint);
    [DllImport("computenetwork.dll", CharSet = CharSet.Unicode)] static extern int HcnDeleteEndpoint(ref Guid id, out IntPtr errorRecord);

    public static Result CreateNetwork(Guid id, string settings)
    {
        IntPtr n, e; int hr = HcnCreateNetwork(ref id, settings, out n, out e);
        if (n != IntPtr.Zero) HcnCloseNetwork(n);
        return new Result { Hr = hr, Doc = Take(e) };
    }
    public static Result CreateEndpoint(Guid network, Guid id, string settings)
    {
        IntPtr n, e; int hr = HcnOpenNetwork(ref network, out n, out e);
        if (hr != 0) return new Result { Hr = hr, Doc = Take(e) };
        try { IntPtr ep; hr = HcnCreateEndpoint(n, ref id, settings, out ep, out e); if (ep != IntPtr.Zero) HcnCloseEndpoint(ep); return new Result { Hr = hr, Doc = Take(e) }; }
        finally { HcnCloseNetwork(n); }
    }
    [DllImport("computenetwork.dll", CharSet = CharSet.Unicode)] static extern int HcnEnumerateNetworks(string query, out IntPtr networks, out IntPtr errorRecord);
    [DllImport("computenetwork.dll", CharSet = CharSet.Unicode)] static extern int HcnQueryNetworkProperties(IntPtr network, string query, out IntPtr properties, out IntPtr errorRecord);
    public static Result EnumerateNetworks() { IntPtr n, e; int hr = HcnEnumerateNetworks("{\"SchemaVersion\":{\"Major\":2,\"Minor\":0}}", out n, out e); Take(e); return new Result { Hr = hr, Doc = Take(n) }; }
    public static Result NetworkProperties(Guid id)
    {
        IntPtr n, e; int hr = HcnOpenNetwork(ref id, out n, out e); Take(e);
        if (hr != 0) return new Result { Hr = hr };
        try { IntPtr p; hr = HcnQueryNetworkProperties(n, "{\"SchemaVersion\":{\"Major\":2,\"Minor\":0}}", out p, out e); Take(e); return new Result { Hr = hr, Doc = Take(p) }; }
        finally { HcnCloseNetwork(n); }
    }
    public static Result DeleteEndpoint(Guid id) { IntPtr e; int hr = HcnDeleteEndpoint(ref id, out e); return new Result { Hr = hr, Doc = Take(e) }; }
    public static Result DeleteNetwork(Guid id) { IntPtr e; int hr = HcnDeleteNetwork(ref id, out e); return new Result { Hr = hr, Doc = Take(e) }; }

    static readonly Guid GpuPartitionAdapter = new Guid("064092b3-625e-43bf-9eb5-dc845897dd59");
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)] static extern int CM_Get_Device_Interface_List_SizeW(out uint len, ref Guid cls, string deviceId, uint flags);
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)] static extern int CM_Get_Device_Interface_ListW(ref Guid cls, string deviceId, char[] buffer, uint len, uint flags);

    public static string[] PartitionableGpus()
    {
        var g = GpuPartitionAdapter;
        uint len;
        if (CM_Get_Device_Interface_List_SizeW(out len, ref g, null, 0) != 0 || len < 2) return new string[0];
        var buf = new char[len];
        if (CM_Get_Device_Interface_ListW(ref g, null, buf, len, 0) != 0) return new string[0];
        var list = new List<string>();
        foreach (var s in new string(buf).Split('\0')) if (s.Length > 0) list.Add(s);
        return list.ToArray();
    }
}
