use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::io::{self, Read, Write};

pub const SERVICE_ID: u128 = 0x94aca5ef_a5b6_45a9_8c15_c7724a63f3da;
pub const HV_GUID_PARENT: u128 = 0xa42e7cda_d03f_480c_9cc2_a4de20abb878;
pub const HV_GUID_CHILDREN: u128 = 0x90db8b89_0d35_4f79_8ce9_49ea0ac8b7cd;
pub const PROTOCOL_VERSION: u64 = 1;
pub const MAX_JSON: usize = 64 * 1024;
pub const MAX_BLOB: usize = 16 * 1024 * 1024;
pub const KIND_JSON: u8 = 1;
pub const KIND_BLOB: u8 = 2;
pub const PING_EVERY_MS: u64 = 2000;
pub const DEAD_AFTER_MS: u64 = 6000;
const TAIL: usize = 40; // ,"m":"<32 hex>"}

#[derive(Debug)]
pub enum Frame {
    Json(Vec<u8>),
    Blob(Vec<u8>),
}

#[derive(Debug)]
pub enum FrameError {
    Io(io::Error),
    TooLarge(u8, u32),
    BadKind(u8),
}

impl std::fmt::Display for FrameError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FrameError::Io(e) => write!(f, "io: {e}"),
            FrameError::TooLarge(k, n) => write!(f, "frame kind {k} of {n} bytes is over the limit"),
            FrameError::BadKind(k) => write!(f, "unknown frame kind {k}"),
        }
    }
}

impl From<io::Error> for FrameError {
    fn from(e: io::Error) -> Self {
        FrameError::Io(e)
    }
}

pub fn read_frame<R: Read>(r: &mut R) -> Result<Frame, FrameError> {
    let mut h = [0u8; 5];
    r.read_exact(&mut h)?;
    let len = u32::from_le_bytes([h[0], h[1], h[2], h[3]]);
    let kind = h[4];
    let max = match kind {
        KIND_JSON => MAX_JSON,
        KIND_BLOB => MAX_BLOB,
        k => return Err(FrameError::BadKind(k)),
    };
    if len as usize > max {
        return Err(FrameError::TooLarge(kind, len));
    }
    let mut buf = vec![0u8; len as usize];
    r.read_exact(&mut buf)?;
    Ok(if kind == KIND_JSON { Frame::Json(buf) } else { Frame::Blob(buf) })
}

pub fn write_frame<W: Write>(w: &mut W, kind: u8, payload: &[u8]) -> io::Result<()> {
    let max = if kind == KIND_JSON { MAX_JSON } else { MAX_BLOB };
    if payload.len() > max {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "frame over the limit"));
    }
    let mut buf = Vec::with_capacity(5 + payload.len());
    buf.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    buf.push(kind);
    buf.extend_from_slice(payload);
    w.write_all(&buf)?;
    w.flush()
}

pub fn sha256(data: &[u8]) -> [u8; 32] {
    Sha256::digest(data).into()
}

pub fn hmac(key: &[u8], parts: &[&[u8]]) -> [u8; 32] {
    let mut k = [0u8; 64];
    if key.len() > 64 {
        k[..32].copy_from_slice(&sha256(key));
    } else {
        k[..key.len()].copy_from_slice(key);
    }
    let mut ipad = k;
    let mut opad = k;
    for b in ipad.iter_mut() {
        *b ^= 0x36;
    }
    for b in opad.iter_mut() {
        *b ^= 0x5c;
    }
    let mut h = Sha256::new();
    h.update(ipad);
    for p in parts {
        h.update(p);
    }
    let inner = h.finalize();
    let mut h = Sha256::new();
    h.update(opad);
    h.update(inner);
    h.finalize().into()
}

pub fn hex(b: &[u8]) -> String {
    const D: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(b.len() * 2);
    for x in b {
        s.push(D[(x >> 4) as usize] as char);
        s.push(D[(x & 15) as usize] as char);
    }
    s
}

pub fn unhex(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(s.get(i..i + 2)?, 16).ok()).collect()
}

pub fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

pub fn is_nonce(s: &str) -> bool {
    s.len() == 32 && s.bytes().all(|c| c.is_ascii_hexdigit())
}

pub fn host_mac(k: &[u8], vm: &str, ng: &str, nh: &str) -> [u8; 32] {
    hmac(k, &[b"host|", vm.as_bytes(), b"|", ng.as_bytes(), b"|", nh.as_bytes()])
}

pub fn guest_mac(k: &[u8], vm: &str, ng: &str, nh: &str) -> [u8; 32] {
    hmac(k, &[b"guest|", vm.as_bytes(), b"|", nh.as_bytes(), b"|", ng.as_bytes()])
}

pub fn session_key(k: &[u8], ng: &str, nh: &str) -> [u8; 32] {
    hmac(k, &[b"session|", ng.as_bytes(), b"|", nh.as_bytes()])
}

pub fn hello(agent_version: &str, ng: &str) -> Vec<u8> {
    serde_json::to_vec(&json!({"t": "hello", "v": PROTOCOL_VERSION, "agent": agent_version, "ng": ng})).unwrap()
}

pub struct Sealer {
    key: [u8; 32],
    seq: u64,
}

impl Sealer {
    pub fn new(key: [u8; 32]) -> Self {
        Sealer { key, seq: 0 }
    }
    /// Seals only if the frame fits `max` bytes; otherwise None and the seq is not used (no gap for the peer).
    pub fn try_seal(&mut self, obj: Value, max: usize) -> Option<Vec<u8>> {
        let f = self.seal(obj);
        if f.len() > max {
            self.seq -= 1;
            return None;
        }
        Some(f)
    }

    pub fn seal(&mut self, mut obj: Value) -> Vec<u8> {
        self.seq += 1;
        if let Some(m) = obj.as_object_mut() {
            m.remove("m");
            m.insert("seq".into(), Value::from(self.seq));
        }
        let mut p = serde_json::to_vec(&obj).unwrap();
        let mac = hmac(&self.key, &[self.seq.to_string().as_bytes(), b"|", &p]);
        p.pop();
        p.extend_from_slice(b",\"m\":\"");
        p.extend_from_slice(hex(&mac[..16]).as_bytes());
        p.extend_from_slice(b"\"}");
        p
    }
}

pub struct Opener {
    key: [u8; 32],
    last: u64,
}

impl Opener {
    pub fn new(key: [u8; 32]) -> Self {
        Opener { key, last: 0 }
    }
    pub fn open(&mut self, frame: &[u8]) -> Result<Value, &'static str> {
        if frame.len() < TAIL + 2 {
            return Err("frame too short");
        }
        let cut = frame.len() - TAIL;
        let tail = &frame[cut..];
        if !tail.starts_with(b",\"m\":\"") || !tail.ends_with(b"\"}") {
            return Err("no MAC tail");
        }
        let mac_hex = std::str::from_utf8(&tail[6..38]).map_err(|_| "bad MAC")?;
        let mac = unhex(mac_hex).ok_or("bad MAC")?;
        let mut p = frame[..cut].to_vec();
        p.push(b'}');
        let v: Value = serde_json::from_slice(&p).map_err(|_| "bad JSON")?;
        let seq = v.get("seq").and_then(Value::as_u64).ok_or("no seq")?;
        let want = hmac(&self.key, &[seq.to_string().as_bytes(), b"|", &p]);
        if !ct_eq(&want[..16], &mac) {
            return Err("wrong MAC");
        }
        if seq != self.last + 1 {
            return Err("wrong seq");
        }
        self.last = seq;
        if !v.is_object() {
            return Err("not an object");
        }
        Ok(v)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hmac_rfc4231_case2() {
        let mac = hmac(b"Jefe", &[b"what do ya want ", b"for nothing?"]);
        assert_eq!(hex(&mac), "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
    }

    #[test]
    fn seal_open_roundtrip_and_tamper() {
        let k = [7u8; 32];
        let mut s = Sealer::new(k);
        let mut o = Opener::new(k);
        let a = s.seal(json!({"t":"ping"}));
        let b = s.seal(json!({"t":"res","id":1,"ok":true,"result":{"x":"é\"}"}}));
        assert_eq!(o.open(&a).unwrap()["t"], "ping");
        assert_eq!(o.open(&b).unwrap()["result"]["x"], "é\"}");
        assert!(o.open(&b).is_err());
        let mut c = s.seal(json!({"t":"ping"}));
        c[3] ^= 1;
        assert!(o.open(&c).is_err());
        let mut s2 = Sealer::new([8u8; 32]);
        let mut o2 = Opener::new(k);
        assert!(o2.open(&s2.seal(json!({"t":"ping"}))).is_err());
    }

    #[test]
    fn frame_limits() {
        let mut big = Vec::new();
        big.extend_from_slice(&((MAX_JSON as u32) + 1).to_le_bytes());
        big.push(KIND_JSON);
        assert!(matches!(read_frame(&mut &big[..]), Err(FrameError::TooLarge(..))));
        let mut bad = vec![0, 0, 0, 0, 9];
        assert!(matches!(read_frame(&mut &bad[..]), Err(FrameError::BadKind(9))));
        bad.clear();
        write_frame(&mut bad, KIND_JSON, b"{}").unwrap();
        assert!(matches!(read_frame(&mut &bad[..]).unwrap(), Frame::Json(v) if v == b"{}"));
    }
}
