// GpuVMAudio.exe: a USB/IP server (protocol 1.1.1) that exports one virtual device, a USB Audio Class 1 speaker,
// 48 kHz 16-bit stereo, full speed. Windows' inbox usbaudio.sys drives it once usbip-win2 attaches it, so the VM gets
// a normal audio output that WASAPI loopback (Sunshine) can capture. The audio itself is consumed at real-time pace
// and discarded; only its level is kept for diagnostics. Listens on 127.0.0.1 only and serves one session at a time.
// Proven in labs/012-usb-audio-over-usbip. Compiled inside the VM by Add-Type (C# 5) and run as LOCAL SERVICE.
// Usage: GpuVMAudio.exe <port> <log file> <status file>
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class UsbAudioServer {
    // pid.codes test VID/PID (1209:0001), private use only; a product needs its own PID.
    static readonly byte[] DeviceDescriptor = {
        18, 1, 0x00, 0x02, 0, 0, 0, 64, 0x09, 0x12, 0x01, 0x00, 0x00, 0x01, 1, 2, 3, 1
    };
    static readonly byte[] ConfigDescriptor = {
        9, 2, 100, 0, 2, 1, 0, 0x80, 50,
        // Interface 0: AudioControl. Header, input terminal (USB streaming) -> output terminal (speaker).
        9, 4, 0, 0, 0, 1, 1, 0, 0,
        9, 0x24, 1, 0x00, 0x01, 30, 0, 1, 1,
        12, 0x24, 2, 1, 0x01, 0x01, 0, 2, 0x03, 0x00, 0, 0,
        9, 0x24, 3, 2, 0x01, 0x03, 0, 1, 0,
        // Interface 1: AudioStreaming. Alt 0 has no bandwidth; alt 1 is PCM 48 kHz 16-bit stereo.
        9, 4, 1, 0, 0, 1, 2, 0, 0,
        9, 4, 1, 1, 1, 1, 2, 0, 0,
        7, 0x24, 1, 1, 1, 0x01, 0x00,
        11, 0x24, 2, 1, 2, 2, 16, 1, 0x80, 0xBB, 0x00,
        // Isochronous OUT endpoint 1, adaptive, 192 bytes every 1 ms frame.
        9, 5, 0x01, 0x09, 0xC0, 0x00, 1, 0, 0,
        7, 0x25, 1, 0, 0, 0, 0
    };
    static readonly string[] Strings = { null, "GpuVM", "GpuVM Audio", "GPUVM0001" };

    // Diagnostics, written to the status file every second.
    static long urbs, isoBytes, nonZeroBytes, controls, unlinks, stalls, sessions;
    static int peak;
    static string lastError = "";
    static StreamWriter log;
    static readonly object logLock = new object();
    static readonly Stopwatch clock = Stopwatch.StartNew();

    [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint period);

    public static void Log(string text) {
        lock (logLock) { if (log != null) { log.WriteLine(DateTime.Now.ToString("HH:mm:ss.fff") + " " + text); log.Flush(); } }
    }

    // Largest transfer a full-speed audio device sees; anything bigger is a misbehaving client.
    const int MaxTransfer = 65536, MaxPackets = 1024;
    static int active;

    public static int Main(string[] args) {
        if (args.Length != 3) { Console.Error.WriteLine("usage: GpuVMAudio.exe <port> <log> <status>"); return 2; }
        Run(int.Parse(args[0]), args[1], args[2]);
        return 0;
    }

    public static void Run(int port, string logPath, string statusPath) {
        timeBeginPeriod(1);
        // A fresh log each start keeps it small; the status file has the running totals.
        log = new StreamWriter(logPath, false, new UTF8Encoding(false));
        var status = new Thread(() => {
            while (true) {
                Thread.Sleep(1000);
                var json = "{\"at\":\"" + DateTime.Now.ToString("o") + "\",\"sessions\":" + Interlocked.Read(ref sessions) +
                    ",\"urbs\":" + Interlocked.Read(ref urbs) + ",\"isoBytes\":" + Interlocked.Read(ref isoBytes) +
                    ",\"nonZeroBytes\":" + Interlocked.Read(ref nonZeroBytes) + ",\"peak\":" + Thread.VolatileRead(ref peak) +
                    ",\"controls\":" + Interlocked.Read(ref controls) + ",\"stalls\":" + Interlocked.Read(ref stalls) +
                    ",\"unlinks\":" + Interlocked.Read(ref unlinks) + ",\"lastError\":\"" + lastError.Replace("\\", "/").Replace("\"", "'") + "\"}";
                try { File.WriteAllText(statusPath, json); } catch { }
            }
        });
        status.IsBackground = true; status.Start();
        var listener = new TcpListener(IPAddress.Loopback, port);
        listener.Start();
        Log("listening on 127.0.0.1:" + port);
        while (true) {
            var client = listener.AcceptTcpClient();
            client.NoDelay = true;
            var t = new Thread(() => Serve(client));
            t.IsBackground = true; t.Start();
        }
    }

    static void Serve(TcpClient client) {
        var stream = client.GetStream();
        try {
            var op = ReadExact(stream, 8);
            int code = BE16(op, 2);
            if (code == 0x8005) {
                var reply = new List<byte>();
                reply.AddRange(new byte[] { 0x01, 0x11, 0x00, 0x05, 0, 0, 0, 0, 0, 0, 0, 1 });
                reply.AddRange(DeviceInfo());
                reply.AddRange(new byte[] { 1, 1, 0, 0, 1, 2, 0, 0 });
                stream.Write(reply.ToArray(), 0, reply.Count);
                Log("devlist");
            }
            else if (code == 0x8003) {
                var busid = Encoding.ASCII.GetString(ReadExact(stream, 32)).TrimEnd('\0');
                Log("import " + busid);
                var reply = new List<byte>();
                // One speaker only: a second import while the first is attached is refused.
                bool ok = busid == "1-1" && Interlocked.CompareExchange(ref active, 1, 0) == 0;
                reply.AddRange(new byte[] { 0x01, 0x11, 0x00, 0x03, 0, 0, 0, (byte)(ok ? 0 : 1) });
                if (ok) reply.AddRange(DeviceInfo());
                stream.Write(reply.ToArray(), 0, reply.Count);
                if (ok) {
                    Interlocked.Increment(ref sessions);
                    try { new Session(stream).Run(); } finally { Interlocked.Exchange(ref active, 0); }
                }
            }
            else Log("unknown op 0x" + code.ToString("X4"));
        }
        catch (Exception e) { lastError = e.Message; Log("closed: " + e.Message); }
        finally { client.Close(); }
    }

    static byte[] DeviceInfo() {
        var b = new byte[312];
        Encoding.ASCII.GetBytes("/sys/devices/platform/gpuvm/usb1/1-1").CopyTo(b, 0);
        Encoding.ASCII.GetBytes("1-1").CopyTo(b, 256);
        PutBE32(b, 288, 1); PutBE32(b, 292, 2); PutBE32(b, 296, 2); // busnum, devnum, speed = full
        PutBE16(b, 300, 0x1209); PutBE16(b, 302, 0x0001); PutBE16(b, 304, 0x0100);
        b[306] = 0; b[307] = 0; b[308] = 0; b[309] = 1; b[310] = 1; b[311] = 2;
        return b;
    }

    class Pending { public uint Seq; public double Due; public uint StartFrame; public byte[] Iso; public int Packets; public int Length; }

    class Session {
        readonly NetworkStream stream;
        readonly object writeLock = new object();
        readonly object queueLock = new object();
        readonly List<Pending> queue = new List<Pending>();
        double nextDue;
        uint frame;
        bool closed;

        public Session(NetworkStream s) { stream = s; }

        public void Run() {
            var completer = new Thread(Complete);
            completer.IsBackground = true; completer.Start();
            try {
                while (true) {
                    var h = ReadExact(stream, 48);
                    uint command = BE32(h, 0), seq = BE32(h, 4), direction = BE32(h, 12), ep = BE32(h, 16);
                    if (command == 1) {
                        int length = (int)BE32(h, 24);
                        uint packets = BE32(h, 32);
                        if (length < 0 || length > MaxTransfer || (packets > MaxPackets && packets != 0xFFFFFFFF)) throw new IOException("oversized request");
                        var setup = new byte[8]; Array.Copy(h, 40, setup, 0, 8);
                        byte[] data = direction == 0 && length > 0 ? ReadExact(stream, length) : null;
                        bool iso = packets != 0 && packets != 0xFFFFFFFF;
                        byte[] isoDesc = iso ? ReadExact(stream, (int)packets * 16) : null;
                        Interlocked.Increment(ref urbs);
                        if (ep == 0) Control(seq, direction, setup, length, data, packets);
                        else if (iso && direction == 0) Queue(seq, (int)packets, isoDesc, data, length);
                        else { Interlocked.Increment(ref stalls); Reply(seq, -32, 0, 0, packets, null, null); }
                    }
                    else if (command == 2) {
                        uint target = BE32(h, 20);
                        bool removed;
                        lock (queueLock) { removed = queue.RemoveAll(p => p.Seq == target) > 0; }
                        Interlocked.Increment(ref unlinks);
                        var r = new byte[48];
                        PutBE32(r, 0, 4); PutBE32(r, 4, seq); PutBE32(r, 20, removed ? unchecked((uint)-104) : 0);
                        Send(r);
                    }
                    else throw new IOException("unknown command " + command);
                }
            }
            finally { lock (queueLock) { closed = true; Monitor.PulseAll(queueLock); } }
        }

        void Control(uint seq, uint direction, byte[] setup, int length, byte[] data, uint packets) {
            Interlocked.Increment(ref controls);
            int type = setup[0], request = setup[1], value = setup[2] | setup[3] << 8, index = setup[4] | setup[5] << 8, wLength = setup[6] | setup[7] << 8;
            byte[] answer = null;
            bool stall = false;
            if ((type & 0x60) == 0x00) {
                if (request == 6 && type == 0x80) {
                    int kind = value >> 8, i = value & 0xFF;
                    if (kind == 1) answer = DeviceDescriptor;
                    else if (kind == 2) answer = ConfigDescriptor;
                    else if (kind == 3 && i == 0) answer = new byte[] { 4, 3, 0x09, 0x04 };
                    else if (kind == 3 && i < Strings.Length) answer = StringDescriptor(Strings[i]);
                    else stall = true;
                }
                else if (request == 0 && (type & 0x80) != 0) answer = new byte[2];
                else if (request == 8) answer = new byte[] { 1 };
                else if (request == 10) answer = new byte[] { 0 };
                else if ((type & 0x80) != 0) stall = true;
            }
            else if ((type & 0x60) == 0x20) {
                // Audio class: GET_* of the sampling frequency answers 48000; anything else reads as zero.
                if ((type & 0x80) != 0) {
                    answer = new byte[wLength];
                    if ((type & 0x1F) == 2 && wLength >= 3) { answer[0] = 0x80; answer[1] = 0xBB; answer[2] = 0x00; }
                }
            }
            else stall = true;
            if (stall) {
                Interlocked.Increment(ref stalls);
                Log("stall type=0x" + type.ToString("X2") + " req=" + request + " value=0x" + value.ToString("X4") + " index=" + index);
                Reply(seq, -32, 0, 0, packets, null, null);
                return;
            }
            if (answer != null) {
                int n = Math.Min(answer.Length, Math.Min(wLength, length));
                var cut = new byte[n]; Array.Copy(answer, cut, n);
                Reply(seq, 0, n, 0, packets, cut, null);
            }
            else Reply(seq, 0, direction == 0 ? length : 0, 0, packets, null, null);
        }

        void Queue(uint seq, int packets, byte[] isoDesc, byte[] data, int length) {
            if (data != null) {
                int p = 0; long nz = 0;
                for (int i = 0; i + 1 < data.Length; i += 2) {
                    int v = Math.Abs((short)(data[i] | data[i + 1] << 8));
                    if (v > p) p = v;
                    if (v != 0) nz += 2;
                }
                if (p > Thread.VolatileRead(ref peak)) Thread.VolatileWrite(ref peak, p);
                Interlocked.Add(ref nonZeroBytes, nz);
                Interlocked.Add(ref isoBytes, data.Length);
            }
            // A real device plays one packet per 1 ms frame; completing at that pace keeps the audio clock right.
            lock (queueLock) {
                double now = clock.Elapsed.TotalMilliseconds;
                if (nextDue < now - 20) nextDue = now;
                nextDue += packets;
                queue.Add(new Pending { Seq = seq, Due = nextDue, StartFrame = frame, Iso = isoDesc, Packets = packets, Length = length });
                frame = (frame + (uint)packets) & 0x7FF;
                Monitor.PulseAll(queueLock);
            }
        }

        void Complete() {
            while (true) {
                Pending next;
                lock (queueLock) {
                    while (!closed && queue.Count == 0) Monitor.Wait(queueLock);
                    if (closed) return;
                    next = queue[0];
                    double wait = next.Due - clock.Elapsed.TotalMilliseconds;
                    if (wait > 0) { Monitor.Wait(queueLock, TimeSpan.FromMilliseconds(Math.Min(wait, 5))); continue; }
                    queue.RemoveAt(0);
                }
                // Every packet delivered whole: actual_length = length, status 0.
                var desc = new byte[next.Packets * 16];
                for (int i = 0; i < next.Packets; i++) {
                    Array.Copy(next.Iso, i * 16, desc, i * 16, 8);
                    Array.Copy(next.Iso, i * 16 + 4, desc, i * 16 + 8, 4);
                }
                try { Reply(next.Seq, 0, next.Length, next.StartFrame, (uint)next.Packets, null, desc); }
                catch (Exception e) { lastError = e.Message; return; }
            }
        }

        void Reply(uint seq, int status, int actual, uint startFrame, uint packets, byte[] data, byte[] iso) {
            var h = new byte[48];
            PutBE32(h, 0, 3); PutBE32(h, 4, seq);
            PutBE32(h, 20, unchecked((uint)status)); PutBE32(h, 24, (uint)actual);
            PutBE32(h, 28, startFrame); PutBE32(h, 32, packets);
            var all = new byte[48 + (data == null ? 0 : data.Length) + (iso == null ? 0 : iso.Length)];
            Array.Copy(h, all, 48);
            if (data != null) Array.Copy(data, 0, all, 48, data.Length);
            if (iso != null) Array.Copy(iso, 0, all, 48 + (data == null ? 0 : data.Length), iso.Length);
            Send(all);
        }

        void Send(byte[] bytes) { lock (writeLock) { stream.Write(bytes, 0, bytes.Length); } }
    }

    static byte[] StringDescriptor(string s) {
        var text = Encoding.Unicode.GetBytes(s);
        var b = new byte[2 + text.Length];
        b[0] = (byte)b.Length; b[1] = 3; text.CopyTo(b, 2);
        return b;
    }

    static byte[] ReadExact(Stream s, int n) {
        var b = new byte[n];
        int read = 0;
        while (read < n) {
            int r = s.Read(b, read, n - read);
            if (r <= 0) throw new EndOfStreamException("connection closed");
            read += r;
        }
        return b;
    }

    static int BE16(byte[] b, int o) { return b[o] << 8 | b[o + 1]; }
    static uint BE32(byte[] b, int o) { return (uint)(b[o] << 24 | b[o + 1] << 16 | b[o + 2] << 8 | b[o + 3]); }
    static void PutBE16(byte[] b, int o, int v) { b[o] = (byte)(v >> 8); b[o + 1] = (byte)v; }
    static void PutBE32(byte[] b, int o, uint v) { b[o] = (byte)(v >> 24); b[o + 1] = (byte)(v >> 16); b[o + 2] = (byte)(v >> 8); b[o + 3] = (byte)v; }
}
