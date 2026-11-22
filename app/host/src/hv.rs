#![allow(dead_code)]

use std::io::{Read, Write};

use windows_sys::core::GUID;
use windows_sys::Win32::Networking::WinSock::*;

const AF_HYPERV: u16 = 34;
const HV_PROTOCOL_RAW: i32 = 1;
const HVSOCKET_CONNECT_TIMEOUT: i32 = 1;
pub const HV_GUID_CHILDREN: u128 = 0x90db8b89_0d35_4f79_8ce9_49ea0ac8b7cd;
pub const HV_GUID_PARENT: u128 = 0xa42e7cda_d03f_480c_9cc2_a4de20abb878;

#[repr(C)]
#[derive(Clone, Copy)]
struct SockaddrHv {
    family: u16,
    reserved: u16,
    vm_id: GUID,
    service_id: GUID,
}

fn addr(vm: u128, service: u128) -> SockaddrHv {
    SockaddrHv { family: AF_HYPERV, reserved: 0, vm_id: GUID::from_u128(vm), service_id: GUID::from_u128(service) }
}

pub fn guid_to_u128(g: &GUID) -> u128 {
    ((g.data1 as u128) << 96) | ((g.data2 as u128) << 80) | ((g.data3 as u128) << 64) | u64::from_be_bytes(g.data4) as u128
}

pub fn fmt_guid(v: u128) -> String {
    let h = format!("{v:032x}");
    format!("{}-{}-{}-{}-{}", &h[0..8], &h[8..12], &h[12..16], &h[16..20], &h[20..32])
}

pub fn parse_guid(s: &str) -> Option<u128> {
    let s = s.trim_matches(|c| c == '{' || c == '}');
    let hex: String = s.chars().filter(|&c| c != '-').collect();
    if s.len() != 36 || hex.len() != 32 {
        return None;
    }
    u128::from_str_radix(&hex, 16).ok()
}

pub fn wsa_error() -> i32 {
    unsafe { WSAGetLastError() }
}

pub fn startup() {
    let mut data: WSADATA = unsafe { std::mem::zeroed() };
    unsafe { WSAStartup(0x0202, &mut data) };
}

pub struct Sock(SOCKET);
unsafe impl Send for Sock {}
unsafe impl Sync for Sock {}

impl Drop for Sock {
    fn drop(&mut self) {
        unsafe { closesocket(self.0) };
    }
}

impl Sock {
    fn new() -> Result<Sock, i32> {
        let s = unsafe { socket(AF_HYPERV as i32, SOCK_STREAM, HV_PROTOCOL_RAW) };
        if s == INVALID_SOCKET { Err(wsa_error()) } else { Ok(Sock(s)) }
    }

    pub fn listen(vm: u128, service: u128) -> Result<Sock, i32> {
        let s = Sock::new()?;
        let a = addr(vm, service);
        if unsafe { bind(s.0, &a as *const SockaddrHv as *const SOCKADDR, std::mem::size_of::<SockaddrHv>() as i32) } != 0
            || unsafe { listen(s.0, 64) } != 0
        {
            return Err(wsa_error());
        }
        Ok(s)
    }

    // The peer's VmId is filled in by Hyper-V, never by the guest.
    pub fn accept(&self) -> Result<(Sock, u128), i32> {
        let mut peer: SockaddrHv = unsafe { std::mem::zeroed() };
        let mut len = std::mem::size_of::<SockaddrHv>() as i32;
        let c = unsafe { accept(self.0, &mut peer as *mut SockaddrHv as *mut SOCKADDR, &mut len) };
        if c == INVALID_SOCKET {
            return Err(wsa_error());
        }
        let c = Sock(c);
        if len as usize != std::mem::size_of::<SockaddrHv>() || peer.family != AF_HYPERV {
            return Err(-1);
        }
        Ok((c, guid_to_u128(&peer.vm_id)))
    }

    pub fn connect(vm: u128, service: u128, timeout_ms: u32) -> Result<Sock, i32> {
        let s = Sock::new()?;
        unsafe { setsockopt(s.0, HV_PROTOCOL_RAW, HVSOCKET_CONNECT_TIMEOUT, &timeout_ms as *const u32 as *const u8, 4) };
        let a = addr(vm, service);
        if unsafe { connect(s.0, &a as *const SockaddrHv as *const SOCKADDR, std::mem::size_of::<SockaddrHv>() as i32) } != 0 {
            return Err(wsa_error());
        }
        Ok(s)
    }

    pub fn set_timeouts(&self, recv_ms: u32, send_ms: u32) {
        unsafe {
            setsockopt(self.0, SOL_SOCKET, SO_RCVTIMEO, &recv_ms as *const u32 as *const u8, 4);
            setsockopt(self.0, SOL_SOCKET, SO_SNDTIMEO, &send_ms as *const u32 as *const u8, 4);
        }
    }

    pub fn shutdown(&self) {
        unsafe { shutdown(self.0, SD_BOTH) };
    }
}

impl Read for &Sock {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let n = unsafe { recv(self.0, buf.as_mut_ptr(), buf.len().min(1 << 30) as i32, 0) };
        if n < 0 { Err(std::io::Error::from_raw_os_error(wsa_error())) } else { Ok(n as usize) }
    }
}

impl Write for &Sock {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let n = unsafe { send(self.0, buf.as_ptr(), buf.len().min(1 << 30) as i32, 0) };
        if n < 0 { Err(std::io::Error::from_raw_os_error(wsa_error())) } else { Ok(n as usize) }
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}
