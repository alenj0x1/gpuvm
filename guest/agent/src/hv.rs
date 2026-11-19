//! Hyper-V sockets (AF_HYPERV, lab 047): a blocking stream with Read/Write, dial (guest) and listen/accept (host
//! harness), plus GUID helpers.
use std::io::{self, Read, Write};
use std::sync::Once;
use windows::core::GUID;
use windows::Win32::Networking::WinSock::*;

pub const AF_HYPERV: u16 = 34;
const HV_PROTOCOL_RAW: i32 = 1;
const HVSOCKET_CONNECT_TIMEOUT: i32 = 1;

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct SockaddrHv {
    pub family: u16,
    pub reserved: u16,
    pub vm_id: GUID,
    pub service_id: GUID,
}

pub fn guid_u128(g: &GUID) -> u128 {
    ((g.data1 as u128) << 96) | ((g.data2 as u128) << 80) | ((g.data3 as u128) << 64) | u64::from_be_bytes(g.data4) as u128
}

/// Lowercase, no braces (the protocol's vmId form).
pub fn fmt_guid(g: &GUID) -> String {
    let h = format!("{:032x}", guid_u128(g));
    format!("{}-{}-{}-{}-{}", &h[0..8], &h[8..12], &h[12..16], &h[16..20], &h[20..32])
}

pub fn parse_guid(s: &str) -> Option<GUID> {
    let hex: String = s.chars().filter(|c| c.is_ascii_hexdigit()).collect();
    if hex.len() != 32 {
        return None;
    }
    u128::from_str_radix(&hex, 16).ok().map(GUID::from_u128)
}

fn startup() {
    static S: Once = Once::new();
    S.call_once(|| unsafe {
        let mut d = WSADATA::default();
        WSAStartup(0x0202, &mut d);
    });
}

fn last() -> io::Error {
    io::Error::from_raw_os_error(unsafe { WSAGetLastError().0 })
}

pub struct HvStream(SOCKET);

unsafe impl Send for HvStream {}
unsafe impl Sync for HvStream {}

impl Drop for HvStream {
    fn drop(&mut self) {
        unsafe {
            closesocket(self.0);
        }
    }
}

impl HvStream {
    /// Sets SO_RCVTIMEO (a recv that waits longer fails with WSAETIMEDOUT) and SO_SNDTIMEO.
    pub fn set_timeouts(&self, recv_ms: u32, send_ms: u32) {
        unsafe {
            setsockopt(self.0, SOL_SOCKET, SO_RCVTIMEO, Some(&recv_ms.to_le_bytes()));
            setsockopt(self.0, SOL_SOCKET, SO_SNDTIMEO, Some(&send_ms.to_le_bytes()));
        }
    }

    /// Ends the connection in both directions (wakes a reader blocked on another thread).
    pub fn shutdown(&self) {
        unsafe {
            shutdown(self.0, SD_BOTH);
        }
    }

    /// Local address as Windows reports it (on the guest side the VmId may or may not be filled in).
    pub fn local(&self) -> Option<SockaddrHv> {
        let mut a = SockaddrHv::default();
        let mut n = std::mem::size_of::<SockaddrHv>() as i32;
        let r = unsafe { getsockname(self.0, &mut a as *mut _ as *mut SOCKADDR, &mut n) };
        (r == 0).then_some(a)
    }
}

impl Read for &HvStream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let want = buf.len().min(1 << 30);
        let n = unsafe { recv(self.0, &mut buf[..want], SEND_RECV_FLAGS(0)) };
        if n < 0 {
            return Err(last());
        }
        Ok(n as usize)
    }
}

impl Write for &HvStream {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let want = buf.len().min(1 << 30);
        let n = unsafe { send(self.0, &buf[..want], SEND_RECV_FLAGS(0)) };
        if n < 0 {
            return Err(last());
        }
        Ok(n as usize)
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn new_socket() -> io::Result<SOCKET> {
    startup();
    unsafe { socket(AF_HYPERV as i32, SOCK_STREAM, HV_PROTOCOL_RAW).map_err(|_| last()) }
}

/// Dials `vm:service` (the guest dials HV_GUID_PARENT), with a connect timeout.
pub fn dial(vm: u128, service: u128, timeout_ms: u32) -> io::Result<HvStream> {
    let s = HvStream(new_socket()?);
    unsafe {
        setsockopt(s.0, HV_PROTOCOL_RAW, HVSOCKET_CONNECT_TIMEOUT, Some(&timeout_ms.to_le_bytes()));
    }
    let a = SockaddrHv { family: AF_HYPERV, reserved: 0, vm_id: GUID::from_u128(vm), service_id: GUID::from_u128(service) };
    let r = unsafe { connect(s.0, &a as *const _ as *const SOCKADDR, std::mem::size_of::<SockaddrHv>() as i32) };
    if r != 0 {
        return Err(last());
    }
    Ok(s)
}

pub struct HvListener(SOCKET);

impl Drop for HvListener {
    fn drop(&mut self) {
        unsafe {
            closesocket(self.0);
        }
    }
}

impl HvListener {
    pub fn bind(vm: u128, service: u128) -> io::Result<HvListener> {
        let s = HvListener(new_socket()?);
        let a = SockaddrHv { family: AF_HYPERV, reserved: 0, vm_id: GUID::from_u128(vm), service_id: GUID::from_u128(service) };
        unsafe {
            if bind(s.0, &a as *const _ as *const SOCKADDR, std::mem::size_of::<SockaddrHv>() as i32) != 0 {
                return Err(last());
            }
            if listen(s.0, 16) != 0 {
                return Err(last());
            }
        }
        Ok(s)
    }

    /// Waits up to `ms` for a connection; Ok(None) on timeout.
    pub fn accept_timeout(&self, ms: i32) -> io::Result<Option<(HvStream, GUID)>> {
        let mut fd = WSAPOLLFD { fd: self.0, events: POLLRDNORM, revents: WSAPOLL_EVENT_FLAGS(0) };
        let n = unsafe { WSAPoll(&mut fd, 1, ms) };
        if n < 0 {
            return Err(last());
        }
        if n == 0 {
            return Ok(None);
        }
        self.accept().map(Some)
    }

    /// Accepts one connection and returns it with the peer's VmId (what identifies the VM, lab 047).
    pub fn accept(&self) -> io::Result<(HvStream, GUID)> {
        let mut a = SockaddrHv::default();
        let mut n = std::mem::size_of::<SockaddrHv>() as i32;
        let s = unsafe { accept(self.0, Some(&mut a as *mut _ as *mut SOCKADDR), Some(&mut n)) }.map_err(|_| last())?;
        Ok((HvStream(s), a.vm_id))
    }
}
