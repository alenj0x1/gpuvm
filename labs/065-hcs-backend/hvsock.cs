using System;
using System.Net;
using System.Net.Sockets;
using System.Text;

public class HvEndPoint : EndPoint
{
    public Guid VmId, ServiceId;
    public HvEndPoint(Guid vm, Guid service) { VmId = vm; ServiceId = service; }
    public override AddressFamily AddressFamily { get { return (AddressFamily)34; } }
    public override SocketAddress Serialize()
    {
        var sa = new SocketAddress((AddressFamily)34, 36);
        var v = VmId.ToByteArray(); var s = ServiceId.ToByteArray();
        for (int i = 0; i < 16; i++) { sa[4 + i] = v[i]; sa[20 + i] = s[i]; }
        return sa;
    }
    public override EndPoint Create(SocketAddress sa)
    {
        var v = new byte[16]; var s = new byte[16];
        for (int i = 0; i < 16; i++) { v[i] = sa[4 + i]; s[i] = sa[20 + i]; }
        return new HvEndPoint(new Guid(v), new Guid(s));
    }
}

public static class HostProbe
{
    public static volatile string Received, Reply, Error, PeerVm;
    public static double AcceptAtSec = -1;
    static System.Diagnostics.Stopwatch sw;

    public static void Start(Guid service, int[] ports)
    {
        sw = System.Diagnostics.Stopwatch.StartNew();
        var l = HvSock.Listen(service);
        var t = new System.Threading.Thread(() =>
        {
            try
            {
                using (var c = l.Accept())
                {
                    AcceptAtSec = sw.Elapsed.TotalSeconds;
                    PeerVm = ((HvEndPoint)c.RemoteEndPoint).VmId.ToString();
                    Received = HvSock.ReadLine(c, 120000);
                    string ip = Received.StartsWith("ip=") ? Received.Substring(3).Trim() : "";
                    var parts = new System.Collections.Generic.List<string>();
                    foreach (var p in ports)
                    {
                        var w = System.Diagnostics.Stopwatch.StartNew(); string r;
                        try { using (var tc = new TcpClient()) { r = tc.ConnectAsync(ip, p).Wait(3000) && tc.Connected ? "open" : "timeout"; } }
                        catch (Exception e) { r = "error:" + (e.InnerException ?? e).GetType().Name; }
                        parts.Add(string.Format("tcp{0}={1}/{2:F0}ms", p, r, w.Elapsed.TotalMilliseconds));
                    }
                    var ping = new System.Net.NetworkInformation.Ping();
                    try { var pr = ping.Send(ip, 2000); parts.Add("ping=" + pr.Status + "/" + pr.RoundtripTime + "ms"); } catch (Exception e) { parts.Add("ping=error:" + e.GetType().Name); }
                    Reply = string.Join(" ", parts);
                    HvSock.SendLine(c, Reply);
                    HvSock.ReadLine(c, 5000);
                }
            }
            catch (Exception e) { Error = e.ToString(); }
            finally { l.Close(); }
        });
        t.IsBackground = true;
        t.Start();
    }
}

// One guest connection kept open: the first line is the guest's "ip=...", later lines are commands and replies.
public static class HostChannel
{
    public static volatile string Hello, Error;
    static Socket conn;

    public static void Start(Guid service)
    {
        var l = HvSock.Listen(service);
        var t = new System.Threading.Thread(() =>
        {
            try { conn = l.Accept(); Hello = HvSock.ReadLine(conn, 120000); }
            catch (Exception e) { Error = e.ToString(); }
            finally { l.Close(); }
        });
        t.IsBackground = true;
        t.Start();
    }

    public static string Ask(string line, int timeoutMs)
    {
        HvSock.SendLine(conn, line);
        return HvSock.ReadLine(conn, timeoutMs);
    }

    public static void Close() { try { if (conn != null) conn.Close(); } catch { } }
}

public static class HvSock
{
    public static readonly Guid Wildcard = Guid.Empty;
    public static readonly Guid Parent = new Guid("a42e7cda-d03f-480c-9cc2-a4de20abb878");

    public static Socket New() { return new Socket((AddressFamily)34, SocketType.Stream, (ProtocolType)1); }

    public static Socket Listen(Guid service)
    {
        var s = New();
        s.Bind(new HvEndPoint(Wildcard, service));
        s.Listen(4);
        return s;
    }

    public static Socket Dial(Guid vm, Guid service) { var s = New(); s.Connect(new HvEndPoint(vm, service)); return s; }

    public static void SendLine(Socket s, string line) { s.Send(Encoding.UTF8.GetBytes(line + "\n")); }

    public static string ReadLine(Socket s, int timeoutMs)
    {
        s.ReceiveTimeout = timeoutMs;
        var sb = new StringBuilder(); var b = new byte[1];
        while (s.Receive(b) == 1) { if (b[0] == 10) break; sb.Append((char)b[0]); }
        return sb.ToString();
    }
}
