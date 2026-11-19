//! The agent channel's wire format and handshake (docs/agents/protocol.md), independent of the transport so it can
//! be tested over any stream. Also compiled into lab 052's stub guest agent (`#[path]`), which uses the guest side.
//!
//! Frames: `u32 length (LE, payload bytes only) | u8 kind | payload`. kind 1 = JSON (max 64 KiB), kind 2 = blob
//! (max 16 MiB) belonging to the JSON frame right before it. After the handshake every JSON frame carries `seq`
//! (exactly last + 1, from 1, per direction) and `m`: the first 16 bytes of HMAC(S, "<seq>|" + P) in hex, where P is
//! the frame's compact JSON without `m`; `m` is always the last member: the frame is P with its final `}` replaced by
//! `,"m":"<32 hex>"}`.

#![allow(dead_code)]

use std::io::{Read, Write};

use serde_json::{json, Map, Value};
use windows_sys::Win32::Security::Cryptography::*;

pub const KIND_JSON: u8 = 1;
pub const KIND_BLOB: u8 = 2;
pub const MAX_JSON: usize = 64 * 1024;
pub const MAX_BLOB: usize = 16 * 1024 * 1024;
/// Before the handshake ends a peer only gets small frames.
pub const MAX_HELLO: usize = 1024;
const MAC_SUFFIX: usize = 40; // ,"m":" + 32 hex + "}

pub fn hmac(key: &[u8], data: &[u8]) -> [u8; 32] {
    let mut out = [0u8; 32];
    let status = unsafe {
        BCryptHash(BCRYPT_HMAC_SHA256_ALG_HANDLE, key.as_ptr(), key.len() as u32, data.as_ptr(), data.len() as u32, out.as_mut_ptr(), 32)
    };
    // Never continue with an all-zero MAC: that would accept anything.
    assert!(status == 0, "BCryptHash failed: {status:#x}");
    out
}

pub fn sha256(data: &[u8]) -> [u8; 32] {
    let mut out = [0u8; 32];
    let status = unsafe { BCryptHash(BCRYPT_SHA256_ALG_HANDLE, std::ptr::null(), 0, data.as_ptr(), data.len() as u32, out.as_mut_ptr(), 32) };
    assert!(status == 0, "BCryptHash failed: {status:#x}");
    out
}

/// What the signed frame before a blob says about it (protocol: "blob", "blobLen", "blobSha256").
pub fn describe_blob(obj: &mut Map<String, Value>, blob: &[u8]) {
    obj.insert("blob".into(), json!(true));
    obj.insert("blobLen".into(), json!(blob.len()));
    obj.insert("blobSha256".into(), json!(hex(&sha256(blob))));
}

/// The blob must be exactly what its signed frame announced.
pub fn check_blob(obj: &Map<String, Value>, blob: &[u8]) -> Result<(), String> {
    if obj.get("blobLen").and_then(Value::as_u64) != Some(blob.len() as u64) {
        return Err("blob length differs from its frame".into());
    }
    let want = obj.get("blobSha256").and_then(Value::as_str).unwrap_or("");
    if !is_hex(want, 64) || !ct_eq(want.as_bytes(), hex(&sha256(blob)).as_bytes()) {
        return Err("blob hash differs from its frame".into());
    }
    Ok(())
}

pub fn random<const N: usize>() -> [u8; N] {
    let mut bytes = [0u8; N];
    let status = unsafe { BCryptGenRandom(std::ptr::null_mut(), bytes.as_mut_ptr(), N as u32, BCRYPT_USE_SYSTEM_PREFERRED_RNG) };
    assert!(status == 0, "BCryptGenRandom failed: {status:#x}");
    bytes
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

pub fn is_hex(s: &str, len: usize) -> bool {
    s.len() == len && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Constant-time comparison (the time doesn't tell how many leading bytes matched).
pub fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

#[derive(Debug)]
pub enum Frame {
    Json(Vec<u8>),
    Blob(Vec<u8>),
}

/// Reads one frame. Anything unknown or over the limit is an error: the caller closes the connection.
pub fn read_frame(r: &mut impl Read, max_json: usize) -> Result<Frame, String> {
    read_frame_of(r, max_json, true)
}

/// `blobs`: false before the peer is authenticated, so a blob frame is refused from its header, before anything is
/// allocated for it (review 2, #9).
fn read_frame_of(r: &mut impl Read, max_json: usize, blobs: bool) -> Result<Frame, String> {
    let mut head = [0u8; 5];
    r.read_exact(&mut head).map_err(|e| format!("read: {e}"))?;
    let len = u32::from_le_bytes(head[..4].try_into().unwrap()) as usize;
    let kind = head[4];
    let limit = match kind {
        KIND_JSON => max_json,
        KIND_BLOB if blobs => MAX_BLOB,
        KIND_BLOB => return Err("blob during the handshake".into()),
        _ => return Err(format!("unknown frame kind {kind}")),
    };
    if len > limit {
        return Err(format!("frame of {len} bytes over the limit of {limit}"));
    }
    if kind == KIND_JSON && len < 2 {
        return Err("empty JSON frame".into());
    }
    let mut payload = vec![0u8; len];
    r.read_exact(&mut payload).map_err(|e| format!("read: {e}"))?;
    Ok(if kind == KIND_JSON { Frame::Json(payload) } else { Frame::Blob(payload) })
}

pub fn write_frame(w: &mut impl Write, kind: u8, payload: &[u8]) -> std::io::Result<()> {
    let mut buf = Vec::with_capacity(5 + payload.len().min(1 << 20));
    buf.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    buf.push(kind);
    if payload.len() <= 1 << 20 {
        buf.extend_from_slice(payload);
        w.write_all(&buf)?;
    } else {
        w.write_all(&buf)?;
        w.write_all(payload)?;
    }
    w.flush()
}

fn write_plain(w: &mut impl Write, value: &Value) -> std::io::Result<()> {
    write_frame(w, KIND_JSON, value.to_string().as_bytes())
}

fn read_plain(r: &mut impl Read) -> Result<Value, String> {
    match read_frame_of(r, MAX_HELLO, false)? {
        Frame::Json(p) => serde_json::from_slice(&p).map_err(|_| "malformed JSON".to_string()),
        Frame::Blob(_) => Err("blob during the handshake".into()),
    }
}

fn frame_mac(key: &[u8; 32], seq: u64, plain: &[u8]) -> String {
    let mut input = format!("{seq}|").into_bytes();
    input.extend_from_slice(plain);
    hex(&hmac(key, &input)[..16])
}

/// Outgoing side of a session: numbers and signs each JSON frame.
pub struct Sealer {
    key: [u8; 32],
    seq: u64,
}

impl Sealer {
    pub fn new(key: [u8; 32]) -> Self {
        Sealer { key, seq: 0 }
    }

    pub fn seal(&mut self, mut obj: Map<String, Value>) -> Vec<u8> {
        self.seq += 1;
        obj.remove("m");
        obj.insert("seq".into(), json!(self.seq));
        let mut plain = Value::Object(obj).to_string().into_bytes();
        let mac = frame_mac(&self.key, self.seq, &plain);
        plain.pop(); // the final '}'
        plain.extend_from_slice(format!(",\"m\":\"{mac}\"}}").as_bytes());
        plain
    }
}

/// Incoming side of a session: checks each JSON frame's signature and number.
pub struct Opener {
    key: [u8; 32],
    seq: u64,
}

impl Opener {
    pub fn new(key: [u8; 32]) -> Self {
        Opener { key, seq: 0 }
    }

    pub fn open(&mut self, payload: &[u8]) -> Result<Map<String, Value>, String> {
        let n = payload.len();
        if n < MAC_SUFFIX + 2 {
            return Err("frame without a signature".into());
        }
        let (body, tail) = payload.split_at(n - MAC_SUFFIX);
        let mac = &tail[6..38];
        if &tail[..6] != b",\"m\":\"" || &tail[38..] != b"\"}" || !std::str::from_utf8(mac).is_ok_and(|m| is_hex(m, 32)) {
            return Err("frame without a signature".into());
        }
        let mut plain = body.to_vec();
        plain.push(b'}');
        let Ok(Value::Object(obj)) = serde_json::from_slice::<Value>(&plain) else {
            return Err("malformed JSON".into());
        };
        let seq = obj.get("seq").and_then(Value::as_u64).ok_or("frame without seq")?;
        if seq != self.seq + 1 {
            return Err(format!("frame out of order (seq {seq}, expected {})", self.seq + 1));
        }
        if !ct_eq(frame_mac(&self.key, seq, &plain).as_bytes(), mac) {
            return Err("bad frame signature".into());
        }
        self.seq = seq;
        Ok(obj)
    }
}

pub struct Session {
    pub sealer: Sealer,
    pub opener: Opener,
    /// The version the guest announced (checked: short, printable).
    pub agent: String,
}

fn session_key(k: &[u8; 32], ng: &str, nh: &str) -> [u8; 32] {
    hmac(k, format!("session|{ng}|{nh}").as_bytes())
}

pub fn printable(s: &str, max: usize) -> bool {
    !s.is_empty() && s.len() <= max && s.bytes().all(|b| (0x20..0x7f).contains(&b))
}

/// Host side: hello → challenge (proves the host knows K) → proof (the guest proves it knows K, for this VmId and
/// this connection's nonces, so a recorded proof is useless).
pub fn host_handshake<S: Read + Write>(s: &mut S, k: &[u8; 32], vm_id: &str) -> Result<Session, String> {
    let hello = read_plain(s)?;
    let ng = hello["ng"].as_str().unwrap_or("");
    let agent = hello["agent"].as_str().unwrap_or("");
    if hello["t"] != "hello" || hello["v"] != 1 || !is_hex(ng, 32) || !printable(agent, 64) {
        return Err("bad hello".into());
    }
    let ng = ng.to_string();
    let nh = hex(&random::<16>());
    let mac = hex(&hmac(k, format!("host|{vm_id}|{ng}|{nh}").as_bytes()));
    write_plain(s, &json!({ "t": "challenge", "nh": nh, "mac": mac })).map_err(|e| format!("write: {e}"))?;
    let proof = read_plain(s)?;
    let got = proof["mac"].as_str().unwrap_or("");
    let want = hex(&hmac(k, format!("guest|{vm_id}|{nh}|{ng}").as_bytes()));
    if proof["t"] != "proof" || !is_hex(got, 64) || !ct_eq(got.as_bytes(), want.as_bytes()) {
        return Err("wrong proof".into());
    }
    let key = session_key(k, &ng, &nh);
    Ok(Session { sealer: Sealer::new(key), opener: Opener::new(key), agent: agent.to_string() })
}

/// Guest side (lab stub and tests). `ng` can be forced to replay a recorded handshake.
pub fn guest_handshake<S: Read + Write>(s: &mut S, k: &[u8; 32], vm_id: &str, agent: &str, ng: Option<String>) -> Result<Session, String> {
    let ng = ng.unwrap_or_else(|| hex(&random::<16>()));
    write_plain(s, &json!({ "t": "hello", "v": 1, "agent": agent, "ng": ng })).map_err(|e| format!("write: {e}"))?;
    let challenge = read_plain(s)?;
    let nh = challenge["nh"].as_str().unwrap_or("").to_string();
    let want = hex(&hmac(k, format!("host|{vm_id}|{ng}|{nh}").as_bytes()));
    if challenge["t"] != "challenge" || !is_hex(&nh, 32) || !ct_eq(challenge["mac"].as_str().unwrap_or("").as_bytes(), want.as_bytes()) {
        return Err("the host didn't prove it knows the secret".into());
    }
    let mac = hex(&hmac(k, format!("guest|{vm_id}|{nh}|{ng}").as_bytes()));
    write_plain(s, &json!({ "t": "proof", "mac": mac })).map_err(|e| format!("write: {e}"))?;
    let key = session_key(k, &ng, &nh);
    Ok(Session { sealer: Sealer::new(key), opener: Opener::new(key), agent: agent.to_string() })
}

// ---------------------------------------------------------------- base64 (blobs on the app's pipe)

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub fn base64(data: &[u8]) -> String {
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let n = (chunk[0] as u32) << 16 | (*chunk.get(1).unwrap_or(&0) as u32) << 8 | *chunk.get(2).unwrap_or(&0) as u32;
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(B64[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

pub fn unbase64(text: &str) -> Option<Vec<u8>> {
    let bytes = text.as_bytes();
    if bytes.len() % 4 != 0 {
        return None;
    }
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    for (index, chunk) in bytes.chunks(4).enumerate() {
        let last = index == bytes.len() / 4 - 1;
        let mut n = 0u32;
        let mut pad = 0;
        for (i, &c) in chunk.iter().enumerate() {
            let v = match c {
                b'A'..=b'Z' => c - b'A',
                b'a'..=b'z' => c - b'a' + 26,
                b'0'..=b'9' => c - b'0' + 52,
                b'+' => 62,
                b'/' => 63,
                b'=' if last && i >= 2 => {
                    pad += 1;
                    0
                }
                _ => return None,
            };
            if pad > 0 && c != b'=' {
                return None;
            }
            n = n << 6 | v as u32;
        }
        out.push((n >> 16) as u8);
        if pad < 2 {
            out.push((n >> 8) as u8);
        }
        if pad < 1 {
            out.push(n as u8);
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handshake_refuses_blob_frames_before_allocating() {
        // A header announcing a 16 MiB blob and no body: refused from the header alone.
        let mut head = (MAX_BLOB as u32).to_le_bytes().to_vec();
        head.push(KIND_BLOB);
        let e = read_plain(&mut head.as_slice()).unwrap_err();
        assert!(e.contains("handshake"), "{e}");
    }
    use std::net::{TcpListener, TcpStream};

    fn pair() -> (TcpStream, TcpStream) {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let a = TcpStream::connect(l.local_addr().unwrap()).unwrap();
        let (b, _) = l.accept().unwrap();
        (a, b)
    }

    const VM: &str = "0b5d1f53-1e33-4b7e-9f0a-2c4d6e8f0a1b";

    #[test]
    fn hmac_known_vector() {
        // RFC 4231 test case 2.
        assert_eq!(hex(&hmac(b"Jefe", b"what do ya want for nothing?")), "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
    }

    #[test]
    fn blob_description() {
        assert_eq!(hex(&sha256(b"abc")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        let mut obj = Map::new();
        describe_blob(&mut obj, b"hello");
        assert!(check_blob(&obj, b"hello").is_ok());
        assert!(check_blob(&obj, b"hellO").is_err());
        assert!(check_blob(&obj, b"hello!").is_err());
        assert!(check_blob(&Map::new(), b"").is_err());
    }

    #[test]
    fn base64_round_trip() {
        for n in 0..50 {
            let data: Vec<u8> = (0..n).map(|i| (i * 37 + 11) as u8).collect();
            assert_eq!(unbase64(&base64(&data)).unwrap(), data);
        }
        assert_eq!(base64(b"foobar"), "Zm9vYmFy");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert!(unbase64("Zm=v").is_none());
        assert!(unbase64("Zm9").is_none());
    }

    fn handshake(guest_key: [u8; 32], guest_vm: &str, ng: Option<String>) -> (Result<Session, String>, Result<Session, String>) {
        let (mut g, mut h) = pair();
        let host = std::thread::spawn(move || host_handshake(&mut h, &[7u8; 32], VM));
        let gvm = guest_vm.to_string();
        let guest = guest_handshake(&mut g, &guest_key, &gvm, "1.0.0", ng);
        drop(g);
        (host.join().unwrap(), guest)
    }

    #[test]
    fn handshake_ok_and_frames() {
        let (mut g, mut h) = pair();
        let host = std::thread::spawn(move || {
            let mut s = host_handshake(&mut h, &[7u8; 32], VM).unwrap();
            let Frame::Json(p) = read_frame(&mut h, MAX_JSON).unwrap() else { panic!() };
            let obj = s.opener.open(&p).unwrap();
            assert_eq!(obj["t"], "ping");
            write_frame(&mut h, KIND_JSON, &s.sealer.seal(json!({"t":"res","id":1}).as_object().unwrap().clone())).unwrap();
            s.agent
        });
        let mut s = guest_handshake(&mut g, &[7u8; 32], VM, "1.0.0", None).unwrap();
        write_frame(&mut g, KIND_JSON, &s.sealer.seal(json!({"t":"ping"}).as_object().unwrap().clone())).unwrap();
        let Frame::Json(p) = read_frame(&mut g, MAX_JSON).unwrap() else { panic!() };
        assert_eq!(s.opener.open(&p).unwrap()["id"], 1);
        assert_eq!(host.join().unwrap(), "1.0.0");
    }

    #[test]
    fn wrong_secret_fails_both_ways() {
        let (host, guest) = handshake([8u8; 32], VM, None);
        // The guest refuses the host's challenge (wrong key): the host never gets a proof.
        assert!(guest.is_err());
        assert!(host.is_err());
    }

    #[test]
    fn wrong_vm_binding_fails() {
        // A guest with the right secret but claiming (or bound to) another VmId.
        let (host, guest) = handshake([7u8; 32], "11111111-2222-3333-4444-555555555555", None);
        assert!(guest.is_err());
        assert!(host.is_err());
    }

    #[test]
    fn replayed_proof_fails() {
        // Record a good handshake, then replay its hello and proof on a new connection.
        let (mut g, mut h) = pair();
        let host = std::thread::spawn(move || host_handshake(&mut h, &[7u8; 32], VM).map(|_| ()));
        let ng = hex(&random::<16>());
        guest_handshake(&mut g, &[7u8; 32], VM, "1.0.0", Some(ng.clone())).unwrap();
        host.join().unwrap().unwrap();
        let old_proof = {
            // Same ng, but the host picks a new nh: the old proof (for the old nh) must fail.
            let (mut g2, mut h2) = pair();
            let host2 = std::thread::spawn(move || host_handshake(&mut h2, &[7u8; 32], VM).map(|_| ()));
            write_plain(&mut g2, &json!({"t":"hello","v":1,"agent":"x","ng":ng})).unwrap();
            let _challenge = read_plain(&mut g2).unwrap();
            let stale_nh = hex(&random::<16>());
            let mac = hex(&hmac(&[7u8; 32], format!("guest|{VM}|{stale_nh}|{ng}").as_bytes()));
            write_plain(&mut g2, &json!({"t":"proof","mac":mac})).unwrap();
            host2.join().unwrap()
        };
        assert!(old_proof.is_err());
    }

    #[test]
    fn oversized_and_malformed_frames() {
        let (mut g, mut h) = pair();
        // Over 64 KiB of JSON.
        g.write_all(&(MAX_JSON as u32 + 1).to_le_bytes()).unwrap();
        g.write_all(&[KIND_JSON]).unwrap();
        assert!(read_frame(&mut h, MAX_JSON).unwrap_err().contains("over the limit"));
        let (mut g, mut h) = pair();
        g.write_all(&[3, 0, 0, 0, 9, 1, 2, 3]).unwrap();
        assert!(read_frame(&mut h, MAX_JSON).unwrap_err().contains("kind"));
        // A big hello is refused before reading it.
        let (mut g, mut h) = pair();
        write_frame(&mut g, KIND_JSON, &vec![b' '; 5000]).unwrap();
        assert!(host_handshake(&mut h, &[7u8; 32], VM).is_err());
        // Malformed JSON hello.
        let (mut g, mut h) = pair();
        write_frame(&mut g, KIND_JSON, b"{not json").unwrap();
        assert!(host_handshake(&mut h, &[7u8; 32], VM).is_err());
    }

    #[test]
    fn tampered_reordered_and_unsigned_frames() {
        let key = [9u8; 32];
        let mut sealer = Sealer::new(key);
        let a = sealer.seal(json!({"t":"evt","event":"x"}).as_object().unwrap().clone());
        let b = sealer.seal(json!({"t":"ping"}).as_object().unwrap().clone());
        // Out of order.
        assert!(Opener::new(key).open(&b).is_err());
        // Replayed.
        let mut o = Opener::new(key);
        o.open(&a).unwrap();
        assert!(o.open(&a).is_err());
        o.open(&b).unwrap();
        // Tampered body.
        let mut t = a.clone();
        let i = t.iter().position(|&c| c == b'x').unwrap();
        t[i] = b'y';
        assert!(Opener::new(key).open(&t).is_err());
        // No signature, or another key.
        assert!(Opener::new(key).open(br#"{"t":"ping","seq":1}"#).is_err());
        assert!(Opener::new([1u8; 32]).open(&a).is_err());
        // A second "m" earlier in the frame doesn't confuse the check.
        let mut s2 = Sealer::new(key);
        let c = s2.seal(json!({"t":"evt","data":{"m":"0123456789abcdef0123456789abcdef"}}).as_object().unwrap().clone());
        assert!(Opener::new(key).open(&c).is_ok());
    }
}
