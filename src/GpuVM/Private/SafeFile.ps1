# Files GpuVM opens as administrator in folders the user chose (an export's destination, a file to import). The
# service checks the path as the user first, but GpuVM opens it later with the elevated token: in between, a folder
# of the path could be swapped for a link to somewhere else (C:\Windows\System32). So each such file is opened once,
# the real path of the open handle is compared with the path asked for, and everything after (writing, reading,
# deleting on failure) goes through that same handle, never through the path again.

if (-not ('GpuVMSafeFile' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class GpuVMSafeFile {
    const uint GENERIC_READ = 0x80000000, GENERIC_WRITE = 0x40000000, DELETE = 0x00010000;
    const uint FILE_SHARE_READ = 1;
    const uint CREATE_NEW = 1, OPEN_EXISTING = 3;
    const uint FILE_ATTRIBUTE_NORMAL = 0x80, FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetFinalPathNameByHandleW(SafeFileHandle h, StringBuilder buffer, uint size, uint flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetLongPathNameW(string shortPath, StringBuilder buffer, uint size);
    [StructLayout(LayoutKind.Sequential)]
    struct FILE_DISPOSITION_INFO { public byte DeleteFile; }
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetFileInformationByHandle(SafeFileHandle h, int infoClass, ref FILE_DISPOSITION_INFO info, uint size);

    public static string FinalPath(SafeFileHandle h) {
        var sb = new StringBuilder(1024);
        uint n = GetFinalPathNameByHandleW(h, sb, (uint)sb.Capacity, 0);
        if (n == 0 || n >= sb.Capacity) throw new IOException("GetFinalPathNameByHandle failed: " + Marshal.GetLastWin32Error());
        string p = sb.ToString();
        return p.StartsWith(@"\\?\UNC\") ? @"\\" + p.Substring(8) : p.StartsWith(@"\\?\") ? p.Substring(4) : p;
    }

    // The long form of a path whose folder exists (8.3 names like USERNA~1 expanded), so it compares with FinalPath.
    public static string LongPath(string path) {
        string full = Path.GetFullPath(path);
        string dir = Path.GetDirectoryName(full);
        if (dir == null) return full;
        var sb = new StringBuilder(1024);
        uint n = GetLongPathNameW(dir, sb, (uint)sb.Capacity);
        if (n == 0 || n >= sb.Capacity) return full;
        return Path.Combine(sb.ToString(), Path.GetFileName(full));
    }

    static SafeFileHandle Check(SafeFileHandle h, string expected, bool created) {
        string real = FinalPath(h);
        if (!string.Equals(real.TrimEnd('\\'), expected.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) {
            if (created) MarkDelete(h);
            h.Dispose();
            throw new IOException("REDIRECTED:" + real);
        }
        return h;
    }

    // A new file (never an existing one, never through a link at its own name), with the right to delete it by handle.
    public static SafeFileHandle CreateNew(string path) {
        string expected = LongPath(path);
        var h = CreateFileW(expected, GENERIC_READ | GENERIC_WRITE | DELETE, 0, IntPtr.Zero, CREATE_NEW,
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);
        if (h.IsInvalid) throw new IOException("CREATE:" + Marshal.GetLastWin32Error());
        return Check(h, expected, true);
    }

    public static SafeFileHandle OpenRead(string path) {
        string expected = LongPath(path);
        var h = CreateFileW(expected, GENERIC_READ, FILE_SHARE_READ, IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);
        if (h.IsInvalid) throw new IOException("OPEN:" + Marshal.GetLastWin32Error());
        return Check(h, expected, false);
    }

    // Deletes the file when its last handle closes (the handle needs DELETE access, as CreateNew gives it).
    public static void MarkDelete(SafeFileHandle h) {
        var info = new FILE_DISPOSITION_INFO { DeleteFile = 1 };
        SetFileInformationByHandle(h, 4, ref info, 1);
    }
}
'@
}

# A plain-words error for what GpuVMSafeFile throws.
function ConvertTo-SafeFileError {
    param([Parameter(Mandatory)][string]$Message, [Parameter(Mandatory)][string]$Path)
    if ($Message -match 'REDIRECTED:(.+)') { return "$Path goes through a link to another folder; choose the real location." }
    if ($Message -match 'CREATE:80\b|CREATE:183\b') { return "$Path already exists. Choose another name." }
    if ($Message -match ':(2|3)\b') { return "$Path doesn't exist." }
    if ($Message -match ':5\b') { return "There's no permission to use $Path." }
    "Couldn't open $Path."
}

# A FileStream over a new file at $Path, checked as above. On failure, Close-GpuVMNewFile -Discard deletes it.
function New-GpuVMSafeFile {
    param([Parameter(Mandatory)][string]$Path)
    try { $handle = [GpuVMSafeFile]::CreateNew($Path) }
    catch { throw (ConvertTo-SafeFileError -Message $_.Exception.InnerException.Message -Path $Path) }
    [IO.FileStream]::new($handle, [IO.FileAccess]::ReadWrite)
}

function Open-GpuVMSafeFile {
    param([Parameter(Mandatory)][string]$Path)
    try { $handle = [GpuVMSafeFile]::OpenRead($Path) }
    catch { throw (ConvertTo-SafeFileError -Message $_.Exception.InnerException.Message -Path $Path) }
    [IO.FileStream]::new($handle, [IO.FileAccess]::Read)
}

function Close-GpuVMNewFile {
    param([Parameter(Mandatory)][IO.FileStream]$Stream, [switch]$Discard)
    if ($Discard) { try { [GpuVMSafeFile]::MarkDelete($Stream.SafeFileHandle) } catch { } }
    $Stream.Dispose()
}
