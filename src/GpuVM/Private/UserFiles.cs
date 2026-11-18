// Files of this PC sent into a VM (Send-GpuVMFile), read with the rights of the person signed in, not the bridge's
// elevated ones. The service checks only the paths in the request as the user; everything below a dropped folder is
// listed and opened here through this process's token with Administrators deny-only and every privilege off, so an
// admin-only file (a VM's disk, a saved password) can't be read, and each file is opened without following a link at
// its name and checked to still be inside the folder that was checked (GetFinalPathNameByHandle), then read through
// that same handle: a folder swapped for a junction after the listing leads outside and is refused.
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace GpuVM
{
    public sealed class UserFileEntry
    {
        public string Rel;
        public string Full;
        public long Size;
        public bool Dir;
    }

    public static class UserFiles
    {
        [StructLayout(LayoutKind.Sequential)]
        struct SID_AND_ATTRIBUTES { public IntPtr Sid; public uint Attributes; }

        [StructLayout(LayoutKind.Sequential)]
        struct BY_HANDLE_FILE_INFORMATION
        {
            public uint Attributes;
            public uint CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }

        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
        [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool ConvertStringSidToSidW(string sid, out IntPtr psid);
        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool CreateRestrictedToken(IntPtr token, uint flags, uint disableCount, SID_AND_ATTRIBUTES[] disable,
            uint deleteCount, IntPtr delete, uint restrictCount, IntPtr restrict, out IntPtr newToken);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint size, uint flags);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern uint GetLongPathNameW(string shortPath, StringBuilder longPath, uint size);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetFileInformationByHandle(SafeFileHandle handle, out BY_HANDLE_FILE_INFORMATION info);

        const uint GENERIC_READ = 0x80000000, FILE_LIST_DIRECTORY = 0x1, SHARE_ALL = 0x7, OPEN_EXISTING = 3;
        const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000, FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        const uint FILE_ATTRIBUTE_DIRECTORY = 0x10, FILE_ATTRIBUTE_REPARSE_POINT = 0x400;
        const uint DISABLE_MAX_PRIVILEGE = 0x1;

        static SafeAccessTokenHandle token;
        static readonly object gate = new object();

        /// <summary>This process's token with Administrators deny-only and no privileges (not even backup): what the
        /// person can open without elevation.</summary>
        public static SafeAccessTokenHandle Token()
        {
            lock (gate)
            {
                if (token != null) return token;
                IntPtr own, admins, restricted;
                if (!OpenProcessToken(GetCurrentProcess(), 0x000F01FF, out own)) throw new IOException("No se pudo leer el token del proceso.");
                try
                {
                    if (!ConvertStringSidToSidW("S-1-5-32-544", out admins)) throw new IOException("SID de Administradores no válido.");
                    var deny = new[] { new SID_AND_ATTRIBUTES { Sid = admins } };
                    if (!CreateRestrictedToken(own, DISABLE_MAX_PRIVILEGE, 1, deny, 0, IntPtr.Zero, 0, IntPtr.Zero, out restricted))
                        throw new IOException("No se pudo crear el token del usuario (" + Marshal.GetLastWin32Error() + ").");
                }
                finally { CloseHandle(own); }
                token = new SafeAccessTokenHandle(restricted);
                return token;
            }
        }

        static SafeFileHandle Open(string path, bool directory)
        {
            SafeFileHandle handle = null;
            int error = 0;
            WindowsIdentity.RunImpersonated(Token(), () =>
            {
                handle = CreateFileW(path, directory ? FILE_LIST_DIRECTORY : GENERIC_READ, SHARE_ALL, IntPtr.Zero, OPEN_EXISTING,
                    FILE_FLAG_OPEN_REPARSE_POINT | (directory ? FILE_FLAG_BACKUP_SEMANTICS : 0), IntPtr.Zero);
                error = Marshal.GetLastWin32Error();
            });
            if (handle == null || handle.IsInvalid)
            {
                if (error == 5) throw new UnauthorizedAccessException("Tu usuario no tiene acceso a " + path + "; no se envía nada.");
                throw new IOException("No se pudo abrir " + path + " (error " + error + "); no se envía nada.");
            }
            return handle;
        }

        static string FinalPath(SafeFileHandle handle)
        {
            var buffer = new StringBuilder(32768);
            uint length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
            if (length == 0 || length >= buffer.Capacity) throw new IOException("No se pudo saber dónde está un archivo; no se envía nada.");
            string path = buffer.ToString();
            if (path.StartsWith(@"\\?\UNC\", StringComparison.Ordinal)) return @"\\" + path.Substring(8);
            if (path.StartsWith(@"\\?\", StringComparison.Ordinal)) return path.Substring(4);
            return path;
        }

        static BY_HANDLE_FILE_INFORMATION Info(SafeFileHandle handle, string path)
        {
            BY_HANDLE_FILE_INFORMATION info;
            if (!GetFileInformationByHandle(handle, out info)) throw new IOException("No se pudo leer " + path + "; no se envía nada.");
            if ((info.Attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) throw new IOException(path + " es un enlace; elige la ubicación real.");
            return info;
        }

        static bool Under(string path, string root)
        {
            return path.Equals(root, StringComparison.OrdinalIgnoreCase)
                || path.StartsWith(root.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase);
        }

        /// <summary>The real location of a chosen file or folder, opened as the person: it must be itself (not a
        /// link, and not reached through one). Everything sent from it must stay under this path.</summary>
        public static string Root(string path, bool directory)
        {
            using (var handle = Open(path, directory))
            {
                var info = Info(handle, path);
                if (((info.Attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) != directory) throw new IOException(path + " cambió mientras se preparaba; vuelve a intentarlo.");
                string real = FinalPath(handle);
                // Short (8.3) names are the same place: compare with the long form of what was asked.
                var longPath = new StringBuilder(32768);
                uint n = GetLongPathNameW(path, longPath, (uint)longPath.Capacity);
                string asked = n > 0 && n < longPath.Capacity ? longPath.ToString() : path;
                if (!real.TrimEnd('\\').Equals(asked.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
                    throw new IOException(path + " pasa por un enlace a otra carpeta; elige la ubicación real.");
                return real;
            }
        }

        /// <summary>Opens a file of a copy for reading, as the person, without following a link at its name, and
        /// only if it is still under the checked root.</summary>
        public static FileStream OpenFile(string path, string root)
        {
            var handle = Open(path, false);
            try
            {
                var info = Info(handle, path);
                if ((info.Attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) throw new IOException(path + " cambió mientras se enviaba; vuelve a intentarlo.");
                string real = FinalPath(handle);
                if (!Under(real, root)) throw new IOException(path + " ahora lleva fuera de la carpeta elegida; no se envía nada.");
                return new FileStream(handle, FileAccess.Read, 1, false);
            }
            catch
            {
                handle.Dispose();
                throw;
            }
        }

        /// <summary>Everything under a checked folder, listed as the person: links are skipped (counted), a folder
        /// that can't be listed stops the copy, and every folder is checked to still be under the root.</summary>
        public static List<UserFileEntry> List(string top, string topRel, string root, out int skipped)
        {
            var entries = new List<UserFileEntry>();
            int links = 0;
            var pending = new Stack<KeyValuePair<string, string>>();
            pending.Push(new KeyValuePair<string, string>(top, topRel));
            WindowsIdentity.RunImpersonated(Token(), () =>
            {
                while (pending.Count > 0)
                {
                    var current = pending.Pop();
                    using (var handle = Open(current.Key, true))
                    {
                        Info(handle, current.Key);
                        if (!Under(FinalPath(handle), root)) throw new IOException(current.Key + " ahora lleva fuera de la carpeta elegida; no se envía nada.");
                    }
                    FileSystemInfo[] children;
                    try { children = new DirectoryInfo(current.Key).GetFileSystemInfos(); }
                    catch (Exception) { throw new UnauthorizedAccessException("No se pudo leer " + current.Key + "; no se envía nada."); }
                    foreach (var child in children)
                    {
                        if ((child.Attributes & FileAttributes.ReparsePoint) != 0) { links++; continue; }
                        string rel = current.Value + "\\" + child.Name;
                        var dir = child as DirectoryInfo;
                        if (dir != null)
                        {
                            entries.Add(new UserFileEntry { Rel = rel, Full = dir.FullName, Size = 0, Dir = true });
                            pending.Push(new KeyValuePair<string, string>(dir.FullName, rel));
                        }
                        else entries.Add(new UserFileEntry { Rel = rel, Full = child.FullName, Size = ((FileInfo)child).Length, Dir = false });
                    }
                }
            });
            skipped = links;
            return entries;
        }
    }
}
