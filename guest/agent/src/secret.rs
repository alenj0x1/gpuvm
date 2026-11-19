//! The per-VM secret K (protocol "Handshake"): `C:\ProgramData\GpuVM\Agent\secret`, 32 raw bytes (64 hex characters
//! are accepted too). The service refuses to use it unless the file and its folder are not links, are owned by SYSTEM
//! or Administrators, and their DACL allows access to SYSTEM and Administrators only (lab 050: any other reader could
//! pose as the agent).
use crate::util::wide;
use std::path::Path;
use windows::core::PCWSTR;
use windows::Win32::Foundation::*;
use windows::Win32::Security::Authorization::*;
use windows::Win32::Security::*;
use windows::Win32::Storage::FileSystem::*;

pub const DIR: &str = r"C:\ProgramData\GpuVM\Agent";
pub const FILE: &str = r"C:\ProgramData\GpuVM\Agent\secret";

fn trusted(sid: PSID) -> bool {
    unsafe { IsWellKnownSid(sid, WinLocalSystemSid).as_bool() || IsWellKnownSid(sid, WinBuiltinAdministratorsSid).as_bool() }
}

/// Ok(()) when only SYSTEM and Administrators can reach the object; Err(reason) otherwise.
pub fn check_acl(path: &str) -> Result<(), String> {
    let w = wide(path);
    unsafe {
        let attrs = GetFileAttributesW(PCWSTR(w.as_ptr()));
        if attrs == INVALID_FILE_ATTRIBUTES {
            return Err(format!("{path} is missing"));
        }
        if attrs & FILE_ATTRIBUTE_REPARSE_POINT.0 != 0 {
            return Err(format!("{path} is a link"));
        }
        let mut owner = PSID::default();
        let mut dacl: *mut ACL = std::ptr::null_mut();
        let mut sd = PSECURITY_DESCRIPTOR::default();
        let r = GetNamedSecurityInfoW(
            PCWSTR(w.as_ptr()),
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            Some(&mut owner),
            None,
            Some(&mut dacl),
            None,
            &mut sd,
        );
        if r.is_err() {
            return Err(format!("{path}: can't read its security ({})", r.0));
        }
        let result = (|| {
            if !trusted(owner) {
                return Err(format!("{path} is owned by someone other than SYSTEM or Administrators"));
            }
            if dacl.is_null() {
                return Err(format!("{path} has no DACL (everyone has access)"));
            }
            let mut info = ACL_SIZE_INFORMATION::default();
            GetAclInformation(dacl, &mut info as *mut _ as *mut _, std::mem::size_of::<ACL_SIZE_INFORMATION>() as u32, AclSizeInformation)
                .map_err(|e| format!("{path}: {e}"))?;
            for i in 0..info.AceCount {
                let mut ace: *mut core::ffi::c_void = std::ptr::null_mut();
                GetAce(dacl, i, &mut ace).map_err(|e| format!("{path}: {e}"))?;
                let header = &*(ace as *const ACE_HEADER);
                match header.AceType as u32 {
                    1 => {} // ACCESS_DENIED_ACE_TYPE
                    0 => { // ACCESS_ALLOWED_ACE_TYPE
                        let a = &*(ace as *const ACCESS_ALLOWED_ACE);
                        let sid = PSID(&a.SidStart as *const u32 as *mut _);
                        if !trusted(sid) {
                            return Err(format!("{path} grants access to an account other than SYSTEM or Administrators"));
                        }
                    }
                    t => return Err(format!("{path} has an ACE of type {t} the agent doesn't accept")),
                }
            }
            Ok(())
        })();
        let _ = LocalFree(Some(HLOCAL(sd.0)));
        result
    }
}

/// Reads K after checking the folder and the file.
pub fn load() -> Result<[u8; 32], String> {
    check_acl(DIR)?;
    check_acl(FILE)?;
    let raw = std::fs::read(Path::new(FILE)).map_err(|e| format!("{FILE}: {e}"))?;
    if raw.len() == 32 {
        let mut k = [0u8; 32];
        k.copy_from_slice(&raw);
        return Ok(k);
    }
    let text = String::from_utf8_lossy(&raw).trim().to_ascii_lowercase();
    match crate::proto::unhex(&text) {
        Some(v) if v.len() == 32 => {
            let mut k = [0u8; 32];
            k.copy_from_slice(&v);
            Ok(k)
        }
        _ => Err(format!("{FILE} must hold 32 bytes (raw or 64 hex characters), it has {}", raw.len())),
    }
}
