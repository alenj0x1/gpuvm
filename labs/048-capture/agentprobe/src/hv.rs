//! Lab 050: what the current token can do with Hyper-V sockets inside the guest.
//! hv --service <guid> [--bind-service <guid>] : socket(), connect to the parent + one round trip (lab 047 protocol),
//! bind + listen on HV_GUID_WILDCARD/<bind-service> (squatting a service name the host might dial).
use crate::util::*;
use std::time::Instant;
use windows::core::GUID;
use windows::Win32::Networking::WinSock::*;

const AF_HYPERV: u16 = 34;
const HV_PROTOCOL_RAW: i32 = 1;

#[repr(C)]
struct SockaddrHv {
    family: u16,
    reserved: u16,
    vm_id: GUID,
    service_id: GUID,
}

fn parse_guid(s: &str) -> GUID {
    let hex: String = s.chars().filter(|c| c.is_ascii_hexdigit()).collect();
    GUID::from_u128(u128::from_str_radix(&hex, 16).unwrap())
}

fn err() -> i32 {
    unsafe { WSAGetLastError().0 }
}

/// read --path f : can this token read the file? (never prints the content, only its length)
pub fn cmd_read(args: &[String]) -> String {
    let p = arg_or(args, "--path", "");
    match std::fs::read(&p) {
        Ok(b) => format!("{{\"path\":{},\"readable\":true,\"bytes\":{}}}", jstr(&p), b.len()),
        Err(e) => format!("{{\"path\":{},\"readable\":false,\"error\":{}}}", jstr(&p), jstr(&e.to_string())),
    }
}

/// regread --value Name : reads HKLM\SOFTWARE\Microsoft\Virtual Machine\External\<Name> (host -> guest KVP items).
/// Prints only whether it could be read and its length.
pub fn cmd_regread(args: &[String]) -> String {
    use windows::core::PCWSTR;
    use windows::Win32::System::Registry::*;
    let name = arg_or(args, "--value", "GpuVMLab050Secret");
    let key: Vec<u16> = "SOFTWARE\\Microsoft\\Virtual Machine\\External".encode_utf16().chain([0]).collect();
    let val: Vec<u16> = name.encode_utf16().chain([0]).collect();
    unsafe {
        let mut h = HKEY::default();
        let r = RegOpenKeyExW(HKEY_LOCAL_MACHINE, PCWSTR(key.as_ptr()), Some(0), KEY_READ, &mut h);
        if r.is_err() {
            return format!("{{\"open\":false,\"err\":{}}}", r.0);
        }
        let mut buf = vec![0u8; 4096];
        let mut len = buf.len() as u32;
        let q = RegQueryValueExW(h, PCWSTR(val.as_ptr()), None, None, Some(buf.as_mut_ptr()), Some(&mut len));
        let _ = RegCloseKey(h);
        if q.is_err() {
            format!("{{\"open\":true,\"read\":false,\"err\":{}}}", q.0)
        } else {
            format!("{{\"open\":true,\"read\":true,\"bytes\":{len}}}")
        }
    }
}

pub fn cmd_hv(args: &[String]) -> String {
    let svc = parse_guid(&arg_or(args, "--service", "b1c0a047-6a5e-4c4b-9e47-047047047047"));
    let bind_svc = parse_guid(&arg_or(args, "--bind-service", "b1c0a050-6a5e-4c4b-9e47-050050050050"));
    let parent = GUID::from_u128(0xa42e7cda_d03f_480c_9cc2_a4de20abb878);
    let mut out = Vec::new();
    unsafe {
        let mut d = WSADATA::default();
        WSAStartup(0x0202, &mut d);
        // connect to the parent
        let s = socket(AF_HYPERV as i32, SOCK_STREAM, HV_PROTOCOL_RAW);
        match s {
            Ok(s) => {
                out.push("\"socket\":\"ok\"".to_string());
                let a = SockaddrHv { family: AF_HYPERV, reserved: 0, vm_id: parent, service_id: svc };
                let t = Instant::now();
                let r = connect(s, &a as *const _ as *const SOCKADDR, std::mem::size_of::<SockaddrHv>() as i32);
                if r != 0 {
                    out.push(format!("\"connect\":{{\"ok\":false,\"err\":{}}}", err()));
                } else {
                    let mut msg = Vec::new();
                    msg.extend_from_slice(&1u32.to_le_bytes());
                    msg.extend_from_slice(&4u32.to_le_bytes());
                    msg.extend_from_slice(&4u32.to_le_bytes());
                    msg.extend_from_slice(b"ping");
                    let sent = send(s, &msg, SEND_RECV_FLAGS(0));
                    let mut buf = [0u8; 4];
                    let got = recv(s, &mut buf, SEND_RECV_FLAGS(0));
                    out.push(format!("\"connect\":{{\"ok\":true,\"ms\":{:.2},\"sent\":{sent},\"received\":{got}}}", t.elapsed().as_secs_f64() * 1e3));
                }
                closesocket(s);
            }
            Err(_) => out.push(format!("\"socket\":{{\"ok\":false,\"err\":{}}}", err())),
        }
        // bind/listen (would let this process answer a host that dials the VM for that service)
        if let Ok(s) = socket(AF_HYPERV as i32, SOCK_STREAM, HV_PROTOCOL_RAW) {
            let a = SockaddrHv { family: AF_HYPERV, reserved: 0, vm_id: GUID::from_u128(0), service_id: bind_svc };
            let r = bind(s, &a as *const _ as *const SOCKADDR, std::mem::size_of::<SockaddrHv>() as i32);
            if r != 0 {
                out.push(format!("\"bind\":{{\"ok\":false,\"err\":{}}}", err()));
            } else {
                let l = listen(s, 4);
                out.push(format!("\"bind\":{{\"ok\":true,\"listen\":{}}}", if l == 0 { "true".to_string() } else { err().to_string() }));
                let hold: u64 = arg_or(args, "--hold-ms", "0").parse().unwrap();
                if hold > 0 {
                    // accept one connection within the hold time, to show a squatter really receives the host's dial
                    let mut fds = FD_SET { fd_count: 1, fd_array: [s; 64] };
                    let tv = TIMEVAL { tv_sec: (hold / 1000) as i32, tv_usec: ((hold % 1000) * 1000) as i32 };
                    let n = select(0, Some(&mut fds), None, None, Some(&tv));
                    out.push(format!("\"acceptedDuringHold\":{}", n > 0));
                }
            }
            closesocket(s);
        }
    }
    format!("{{{}}}", out.join(","))
}
