using System;
using System.ComponentModel;
using System.Net;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

namespace NetworkMonitor {
    public sealed class SourceReply {
        public IPStatus Status { get; set; }
        public long RoundtripTime { get; set; }
    }

    public static class SourcePing {
        [DllImport("iphlpapi.dll", SetLastError = true)]
        private static extern IntPtr IcmpCreateFile();
        [DllImport("iphlpapi.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool IcmpCloseHandle(IntPtr handle);
        [DllImport("iphlpapi.dll", SetLastError = true)]
        private static extern uint IcmpSendEcho2Ex(IntPtr handle, IntPtr evt,
            IntPtr callback, IntPtr context, uint source, uint destination,
            byte[] data, ushort size, IntPtr options, IntPtr reply,
            uint replySize, uint timeout);

        public static Task<SourceReply> SendAsync(IPAddress source, IPAddress destination, int timeout) {
            return Task.Run(() => Send(source, destination, timeout));
        }

        private static SourceReply Send(IPAddress source, IPAddress destination, int timeout) {
            if (source.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork ||
                destination.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork)
                throw new ArgumentException("Selected-source ping requires IPv4.");
            IntPtr handle = IcmpCreateFile();
            if (handle == new IntPtr(-1) || handle == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error());
            IntPtr buffer = IntPtr.Zero;
            try {
                buffer = Marshal.AllocHGlobal(4096);
                byte[] payload = new byte[32];
                uint replies = IcmpSendEcho2Ex(handle, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                    BitConverter.ToUInt32(source.GetAddressBytes(), 0),
                    BitConverter.ToUInt32(destination.GetAddressBytes(), 0),
                    payload, (ushort)payload.Length, IntPtr.Zero, buffer, 4096, (uint)timeout);
                if (replies == 0) {
                    int error = Marshal.GetLastWin32Error();
                    // IP status codes describe packet/network failures. Other errors are local failures.
                    if (error >= 11000 && error <= 11050)
                        return new SourceReply { Status = (IPStatus)error };
                    throw new Win32Exception(error);
                }
                // The first three DWORD fields of ICMP_ECHO_REPLY have identical offsets on x86/x64.
                return new SourceReply {
                    Status = (IPStatus)Marshal.ReadInt32(buffer, 4),
                    RoundtripTime = unchecked((uint)Marshal.ReadInt32(buffer, 8))
                };
            } finally {
                if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
                IcmpCloseHandle(handle);
            }
        }
    }
}
