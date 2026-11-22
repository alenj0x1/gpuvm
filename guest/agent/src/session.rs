use crate::token::*;
use crate::util::wide;
use std::fs::File;
use std::os::windows::io::FromRawHandle;
use windows::core::{PCWSTR, PWSTR};
use windows::Win32::Foundation::*;
use windows::Win32::Security::*;
use windows::Win32::Storage::FileSystem::*;
use windows::Win32::System::Environment::*;
use windows::Win32::System::JobObjects::*;
use windows::Win32::System::Pipes::CreatePipe;
use windows::Win32::System::RemoteDesktop::*;
use windows::Win32::System::Threading::*;

pub struct Helper {
    pub pid: u32,
    pub session: u32,
    /// DOMAIN\name of the token the service launched it with (never what the helper says about itself)
    pub user: String,
    pub process: std::sync::Arc<Owned>,
    pub job: Owned,
    pub to_helper: File,
    pub from_helper: File,
}

impl Helper {
    pub fn exited(&self) -> bool {
        unsafe { WaitForSingleObject(self.process.0, 0) == WAIT_OBJECT_0 }
    }
    pub fn kill(&self) {
        unsafe {
            let _ = TerminateProcess(self.process.0, 1);
        }
    }
}

pub fn active_session() -> Option<u32> {
    let s = unsafe { WTSGetActiveConsoleSessionId() };
    (s != 0xFFFF_FFFF).then_some(s)
}

pub fn user_token(session: u32) -> Result<Owned, String> {
    unsafe {
        let mut tok = HANDLE::default();
        WTSQueryUserToken(session, &mut tok).map_err(|e| format!("no signed-in user in session {session} ({})", e.code().0 & 0xffff))?;
        let tok = Owned(tok);
        if token_elevated(tok.0) {
            return Err("the signed-in user's token is elevated (UAC off?): the helper never runs elevated".into());
        }
        match token_integrity(tok.0) {
            Some(il) if il <= IL_MEDIUM => {}
            il => return Err(format!("the signed-in user's token has integrity {il:?}, above medium")),
        }
        let (agent, mode) = agent_mode();
        let sid = token_sid(tok.0).ok_or("can't read the signed-in user's SID")?;
        helper_allowed(agent.as_deref(), &mode, &sid, token_elevation_type(tok.0))?;
        Ok(tok)
    }
}

fn pipe() -> Result<(HANDLE, HANDLE), String> {
    unsafe {
        let sa = SECURITY_ATTRIBUTES { nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: std::ptr::null_mut(), bInheritHandle: TRUE };
        let (mut r, mut w) = (HANDLE::default(), HANDLE::default());
        CreatePipe(&mut r, &mut w, Some(&sa), 1 << 20).map_err(|e| format!("CreatePipe {e}"))?;
        Ok((r, w))
    }
}

pub fn launch(exe: &std::path::Path, session: u32) -> Result<Helper, String> {
    let tok = user_token(session)?;
    let user = token_user(tok.0).0;
    // Default process DACL: a restricted one broke Windows.Graphics.Capture with E_ACCESSDENIED (the process opens itself by id).
    unsafe {
        let (in_r, in_w) = pipe()?;
        let (out_r, out_w) = pipe()?;
        let _ = SetHandleInformation(in_w, HANDLE_FLAG_INHERIT.0, HANDLE_FLAGS(0));
        let _ = SetHandleInformation(out_r, HANDLE_FLAG_INHERIT.0, HANDLE_FLAGS(0));
        let to_helper = File::from_raw_handle(in_w.0 as _);
        let from_helper = File::from_raw_handle(out_r.0 as _);
        let child_in = Owned(in_r);
        let child_out = Owned(out_w);
        let nul_name = wide("NUL");
        let sa = SECURITY_ATTRIBUTES { nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: std::ptr::null_mut(), bInheritHandle: TRUE };
        let nul = Owned(
            CreateFileW(PCWSTR(nul_name.as_ptr()), (FILE_GENERIC_WRITE).0, FILE_SHARE_READ | FILE_SHARE_WRITE, Some(&sa), OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, None)
                .map_err(|e| format!("NUL {e}"))?,
        );

        // explicit inherit list: exactly these three handles
        let handles = [child_in.0, child_out.0, nul.0];
        let mut size = 0usize;
        let _ = InitializeProcThreadAttributeList(None, 1, None, &mut size);
        let mut attr_buf = vec![0u8; size];
        let attrs = LPPROC_THREAD_ATTRIBUTE_LIST(attr_buf.as_mut_ptr() as _);
        InitializeProcThreadAttributeList(Some(attrs), 1, None, &mut size).map_err(|e| format!("attr list {e}"))?;
        UpdateProcThreadAttribute(
            attrs,
            0,
            PROC_THREAD_ATTRIBUTE_HANDLE_LIST as usize,
            Some(handles.as_ptr() as *const _),
            std::mem::size_of_val(&handles),
            None,
            None,
        )
        .map_err(|e| format!("handle list {e}"))?;

        let mut desktop = wide("winsta0\\default");
        let mut si = STARTUPINFOEXW::default();
        si.StartupInfo.cb = std::mem::size_of::<STARTUPINFOEXW>() as u32;
        si.StartupInfo.lpDesktop = PWSTR(desktop.as_mut_ptr());
        si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        si.StartupInfo.hStdInput = child_in.0;
        si.StartupInfo.hStdOutput = child_out.0;
        si.StartupInfo.hStdError = nul.0;
        si.lpAttributeList = attrs;

        // the user's own environment: with SYSTEM's, Edge never opened
        let mut env: *mut core::ffi::c_void = std::ptr::null_mut();
        let have_env = CreateEnvironmentBlock(&mut env, Some(tok.0), false).is_ok();
        let exe_w = wide(&exe.to_string_lossy());
        let mut cmd = wide(&format!("\"{}\" helper", exe.display()));
        let mut pi = PROCESS_INFORMATION::default();
        let r = CreateProcessAsUserW(
            Some(tok.0),
            PCWSTR(exe_w.as_ptr()),
            Some(PWSTR(cmd.as_mut_ptr())),
            None,
            None,
            true,
            EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW | CREATE_SUSPENDED | if have_env { CREATE_UNICODE_ENVIRONMENT } else { PROCESS_CREATION_FLAGS(0) },
            if have_env { Some(env as *const _) } else { None },
            PCWSTR::null(),
            &si.StartupInfo,
            &mut pi,
        );
        if have_env {
            let _ = DestroyEnvironmentBlock(env);
        }
        DeleteProcThreadAttributeList(attrs);
        r.map_err(|e| format!("CreateProcessAsUser {e}"))?;
        let process = std::sync::Arc::new(Owned(pi.hProcess));
        let thread = Owned(pi.hThread);

        let job = Owned(CreateJobObjectW(None, PCWSTR::null()).map_err(|e| format!("job {e}"))?);
        let mut lim = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        lim.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_BREAKAWAY_OK;
        let _ = SetInformationJobObject(job.0, JobObjectExtendedLimitInformation, &lim as *const _ as *const _, std::mem::size_of_val(&lim) as u32);
        if let Err(e) = AssignProcessToJobObject(job.0, process.0) {
            let _ = TerminateProcess(process.0, 1);
            return Err(format!("job assign {e}"));
        }
        ResumeThread(thread.0);
        drop((child_in, child_out, nul));
        Ok(Helper { pid: pi.dwProcessId, session, user, process, job, to_helper, from_helper })
    }
}
