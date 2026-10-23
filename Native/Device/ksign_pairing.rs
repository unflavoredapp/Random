//! Ksign's cancellable iOS pairing bridge. Built into the existing idevice FFI
//! library, so there is only one Rust runtime and one version of the protocol.
//! Bonjour advertising belongs to Swift/NetService, not raw multicast sockets.
//!
//! Hardening over the first version:
//! - the listener keeps accepting until a real device completes the handshake, so a stray or
//!   hostile connection (a port scan, a misrouted request) can't use up the only `accept()`;
//!   peers outside the local network are dropped and silent peers are dropped after a few seconds;
//! - an existing host identity (key pair + altIRK) can be passed back in, so re-pairing doesn't
//!   invalidate pairing files already handed to other apps;
//! - model name and timeout are parameters (`ksign_pairing_run_ex`);
//! - cancellation wakes the waiting task immediately instead of polling;
//! - a panic becomes an error instead of aborting the app;
//! - the returned credentials are wiped from memory when Swift frees them.

use std::{
    ffi::{CStr, CString, c_char, c_void},
    net::{IpAddr, Ipv4Addr},
    panic::{AssertUnwindSafe, catch_unwind},
    sync::atomic::{AtomicBool, Ordering},
    time::Duration,
};

use idevice::remote_pairing::{PairableHost, PairableHostInfo, RpPairingFile, RpPairingSocket};
use tokio::sync::Notify;
use crate::{IdeviceFfiError, ffi_err, run_sync_local};

const DEFAULT_MODEL: &str = "Mac17,7";
const DEFAULT_TIMEOUT_SECS: u32 = 180;
const MAX_TIMEOUT_SECS: u32 = 900;
/// The device speaks first. A peer that stays silent this long is a scanner, not an iPhone.
const FIRST_BYTE_TIMEOUT: Duration = Duration::from_secs(10);

pub struct KsignPairingSession {
    cancelled: AtomicBool,
    wake: Notify,
}

#[unsafe(no_mangle)]
pub extern "C" fn ksign_pairing_new() -> *mut KsignPairingSession {
    Box::into_raw(Box::new(KsignPairingSession {
        cancelled: AtomicBool::new(false),
        wake: Notify::new(),
    }))
}

/// Safe concurrently with run. The caller must keep the session alive until run returns.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ksign_pairing_cancel(session: *mut KsignPairingSession) {
    if let Some(session) = unsafe { session.as_ref() } {
        session.cancelled.store(true, Ordering::Release);
        // `notify_one` stores a permit when nobody is waiting yet, so a cancel that lands
        // just before `run` starts waiting is not lost.
        session.wake.notify_one();
    }
}

/// Call only after run has returned and all cancel calls have completed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ksign_pairing_free(session: *mut KsignPairingSession) {
    if !session.is_null() { drop(unsafe { Box::from_raw(session) }); }
}

/// Same as `ksign_pairing_run_ex` with the default model, the default timeout and a fresh identity.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ksign_pairing_run(
    session: *mut KsignPairingSession,
    name: *const c_char,
    callback: Option<extern "C" fn(*mut c_void, i32, *const c_char)>,
    context: *mut c_void,
    out_record: *mut *mut c_char,
) -> *mut IdeviceFfiError {
    unsafe {
        ksign_pairing_run_ex(
            session, name, std::ptr::null(), 0, std::ptr::null(), callback, context, out_record,
        )
    }
}

/// Callback strings are borrowed for the duration of the callback only.
/// event=0: JSON {identifier,port,txt}; event=1: PIN. Callbacks run off the UI thread.
/// On success out_record receives JSON containing credentials and host identity.
/// Free that string with ksign_pairing_string_free. Never log it.
/// All non-optional pointers must be valid; call run at most once per session.
///
/// `model`: hardware model shown on the device; NULL or empty = "Mac17,7".
/// `timeout_secs`: how long to wait for a device; 0 = 180, capped at 900.
/// `identity_json`: NULL for a fresh host identity, or the record a previous run returned
/// (`pairing_plist` + `host_alt_irk`). Reusing it keeps pairing files already given to other
/// apps valid, and lets a device that paired before recognise this host. A value that can't
/// be parsed is ignored and a fresh identity is generated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ksign_pairing_run_ex(
    session: *mut KsignPairingSession,
    name: *const c_char,
    model: *const c_char,
    timeout_secs: u32,
    identity_json: *const c_char,
    callback: Option<extern "C" fn(*mut c_void, i32, *const c_char)>,
    context: *mut c_void,
    out_record: *mut *mut c_char,
) -> *mut IdeviceFfiError {
    // A panic must not unwind into Swift (that aborts the whole app): report it as an error instead.
    match catch_unwind(AssertUnwindSafe(|| unsafe {
        run_inner(session, name, model, timeout_secs, identity_json, callback, context, out_record)
    })) {
        Ok(result) => result,
        Err(payload) => {
            let detail = payload.downcast_ref::<&str>().map(|s| s.to_string())
                .or_else(|| payload.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "unknown".into());
            tracing::error!("ksign pairing panicked: {detail}");
            ffi_err!(idevice::IdeviceError::InternalError(
                "Pairing hit an internal error. Try again.".into()
            ))
        }
    }
}

#[allow(clippy::too_many_arguments)]
unsafe fn run_inner(
    session: *mut KsignPairingSession,
    name: *const c_char,
    model: *const c_char,
    timeout_secs: u32,
    identity_json: *const c_char,
    callback: Option<extern "C" fn(*mut c_void, i32, *const c_char)>,
    context: *mut c_void,
    out_record: *mut *mut c_char,
) -> *mut IdeviceFfiError {
    if session.is_null() || name.is_null() || out_record.is_null() {
        return ffi_err!(idevice::IdeviceError::FfiInvalidArg);
    }
    unsafe { *out_record = std::ptr::null_mut(); }
    if unsafe { &*session }.cancelled.load(Ordering::Acquire) {
        return ffi_err!(idevice::IdeviceError::InternalError("Pairing cancelled".into()));
    }
    let name = match unsafe { CStr::from_ptr(name) }.to_str() {
        Ok(name) => name.to_owned(),
        Err(_) => return ffi_err!(idevice::IdeviceError::FfiInvalidString),
    };
    let model = match optional_str(model) {
        Ok(Some(m)) if !m.is_empty() => m,
        Ok(_) => DEFAULT_MODEL.to_owned(),
        Err(()) => return ffi_err!(idevice::IdeviceError::FfiInvalidString),
    };
    let identity = match optional_str(identity_json) {
        Ok(Some(json)) if !json.is_empty() => {
            let parsed = parse_identity(&json);
            if parsed.is_none() { tracing::warn!("ksign pairing: saved identity unreadable, generating a new one"); }
            parsed
        }
        Ok(_) => None,
        Err(()) => return ffi_err!(idevice::IdeviceError::FfiInvalidString),
    };
    let timeout = Duration::from_secs(u64::from(clamp_timeout(timeout_secs)));
    let session = unsafe { &*session };
    let emit = |event: i32, value: String| {
        if let (Some(callback), Ok(value)) = (callback, CString::new(value)) {
            callback(context, event, value.as_ptr());
        }
    };
    let result: Result<String, String> = run_sync_local(async {
        let pairing = async {
            let listener = tokio::net::TcpListener::bind((Ipv4Addr::UNSPECIFIED, 0))
                .await.map_err(|e| format!("Cannot listen for pairing: {e}"))?;
            let port = listener.local_addr().map_err(|e| e.to_string())?.port();
            let mut host = PairableHostInfo::generate(&name, &model);
            let credentials = match identity {
                Some(saved) => {
                    host.alt_irk = saved.alt_irk;
                    let mut file = saved.file;
                    // The altIRK stored in the file belongs to the previous device, not to us.
                    file.alt_irk = None;
                    file
                }
                None => RpPairingFile::generate(&name),
            };
            let host_alt_irk = host.alt_irk;
            let txt: std::collections::BTreeMap<_, _> = host.mdns_txt_records(&credentials.identifier)
                .into_iter().collect();
            emit(0, serde_json::json!({
                "identifier": credentials.identifier, "port": port, "txt": txt
            }).to_string());

            // Keep accepting until a device finishes the handshake. One stray connection must not
            // end the run, so connections that aren't an iPhone on this network are dropped.
            let pin_issued = AtomicBool::new(false);
            let (paired, peer) = loop {
                let (stream, addr) = listener.accept().await.map_err(|e| e.to_string())?;
                if !is_local_peer(addr.ip()) {
                    tracing::warn!("ksign pairing: dropped a connection from outside the local network ({addr})");
                    continue;
                }
                let mut probe = [0u8; 1];
                match tokio::time::timeout(FIRST_BYTE_TIMEOUT, stream.peek(&mut probe)).await {
                    Ok(Ok(n)) if n > 0 => {}
                    _ => {
                        tracing::info!("ksign pairing: dropped a silent connection from {addr}");
                        continue;
                    }
                }
                pin_issued.store(false, Ordering::Release);
                // Each attempt works on its own copy so a failed one can't leave half-updated credentials.
                let mut attempt = credentials.clone();
                let mut responder = PairableHost::new(RpPairingSocket::new_device(stream), host.clone());
                let flag = &pin_issued;
                match responder.accept(&mut attempt, |pin| {
                    flag.store(true, Ordering::Release);
                    async { emit(1, pin); }
                }).await {
                    Ok(peer) => break (attempt, peer),
                    // A failure after the PIN was shown is the real device's answer (wrong PIN, declined): report it.
                    Err(e) if pin_issued.load(Ordering::Acquire) => return Err(format!("Pairing failed: {e}")),
                    // Before the PIN it was something else talking to us: ignore it and keep waiting.
                    Err(e) => tracing::info!("ksign pairing: ignored a failed handshake from {addr}: {e}"),
                }
            };
            let plist = String::from_utf8(paired.to_bytes()).map_err(|e| e.to_string())?;
            Ok(serde_json::json!({
                "pairing_plist": plist,
                "host_alt_irk": host_alt_irk,
                "device_udid": peer.remotepairing_udid,
                "device_name": peer.name
            }).to_string())
        };
        tokio::select! {
            result = pairing => result,
            _ = wait_cancelled(session) => Err("Pairing cancelled".into()),
            _ = tokio::time::sleep(timeout) =>
                Err("Pairing timed out. Return to AirShare and try again.".into()),
        }
    });
    match result {
        Ok(record) => {
            match CString::new(record) {
                Ok(record) => { unsafe { *out_record = record.into_raw(); } std::ptr::null_mut() }
                Err(_) => ffi_err!(idevice::IdeviceError::FfiInvalidString),
            }
        }
        Err(message) => ffi_err!(idevice::IdeviceError::InternalError(message)),
    }
}

struct SavedIdentity {
    file: RpPairingFile,
    alt_irk: [u8; 16],
}

/// Reads `{"pairing_plist": "<xml plist>", "host_alt_irk": [16 numbers]}` as `ksign_pairing_run` returns it.
fn parse_identity(json: &str) -> Option<SavedIdentity> {
    let value: serde_json::Value = serde_json::from_str(json).ok()?;
    let file = RpPairingFile::from_bytes(value.get("pairing_plist")?.as_str()?.as_bytes()).ok()?;
    let irk = value.get("host_alt_irk")?.as_array()?;
    if irk.len() != 16 { return None; }
    let mut alt_irk = [0u8; 16];
    for (slot, item) in alt_irk.iter_mut().zip(irk) {
        *slot = u8::try_from(item.as_u64()?).ok()?;
    }
    Some(SavedIdentity { file, alt_irk })
}

/// `Ok(None)` for NULL, `Err` for text that isn't UTF-8.
fn optional_str(p: *const c_char) -> Result<Option<String>, ()> {
    if p.is_null() { return Ok(None); }
    unsafe { CStr::from_ptr(p) }.to_str().map(|s| Some(s.to_owned())).map_err(|_| ())
}

fn clamp_timeout(secs: u32) -> u32 {
    if secs == 0 { DEFAULT_TIMEOUT_SECS } else { secs.min(MAX_TIMEOUT_SECS) }
}

/// True for addresses an iPhone on the same Wi-Fi, hotspot or VPN-less LAN would connect from:
/// loopback, private (10/8, 172.16/12, 192.168/16), link-local, and carrier-grade NAT (100.64/10).
fn is_local_peer(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let o = v4.octets();
            v4.is_loopback() || v4.is_private() || v4.is_link_local() || (o[0] == 100 && (64..128).contains(&o[1]))
        }
        IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped() { return is_local_peer(IpAddr::V4(v4)); }
            let first = v6.segments()[0];
            v6.is_loopback() || (first & 0xffc0) == 0xfe80 /* link-local */ || (first & 0xfe00) == 0xfc00 /* unique local */
        }
    }
}

/// Resolves as soon as the session is cancelled, without polling.
async fn wait_cancelled(session: &KsignPairingSession) {
    loop {
        let woken = session.wake.notified();
        if session.cancelled.load(Ordering::Acquire) { return; }
        woken.await;
    }
}

/// Wipes the credentials from memory before freeing them.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ksign_pairing_string_free(value: *mut c_char) {
    if value.is_null() { return; }
    // `from_raw` first, while the terminating NUL still gives the right length.
    let mut bytes = unsafe { CString::from_raw(value) }.into_bytes_with_nul();
    for byte in bytes.iter_mut() {
        unsafe { std::ptr::write_volatile(byte, 0) };
    }
    std::sync::atomic::compiler_fence(Ordering::SeqCst);
    drop(bytes);
}

#[cfg(test)]
mod tests {
    use super::*;

    extern "C" fn cancel_when_listening(context: *mut c_void, event: i32, payload: *const c_char) {
        if event == 0 {
            let value: serde_json::Value = serde_json::from_str(unsafe { CStr::from_ptr(payload) }.to_str().unwrap()).unwrap();
            assert!(value["port"].as_u64().unwrap() > 0);
            assert!(value["txt"]["authTag"].is_string());
            unsafe { ksign_pairing_cancel(context.cast()); }
        }
    }

    #[test]
    fn cancellation_closes_a_waiting_listener_without_a_device() {
        unsafe {
            let session = ksign_pairing_new();
            let name = CString::new("Ksign test").unwrap();
            let mut record = std::ptr::null_mut();
            let started = std::time::Instant::now();
            let error = ksign_pairing_run(session, name.as_ptr(), Some(cancel_when_listening), session.cast(), &mut record);
            assert!(!error.is_null());
            assert!(record.is_null());
            assert!(started.elapsed() < Duration::from_secs(5));
            assert!(CStr::from_ptr((*error).message).to_str().unwrap().contains("cancelled"));
            crate::idevice_error_free(error);
            ksign_pairing_free(session);
        }
    }

    #[test]
    fn a_stray_connection_does_not_end_pairing() {
        // Connect to the advertised port and stay silent: the run must keep listening (and still be cancellable).
        extern "C" fn poke_then_cancel(context: *mut c_void, event: i32, payload: *const c_char) {
            if event != 0 { return; }
            let value: serde_json::Value = serde_json::from_str(unsafe { CStr::from_ptr(payload) }.to_str().unwrap()).unwrap();
            let port = value["port"].as_u64().unwrap() as u16;
            let addr = context as usize;
            std::thread::spawn(move || {
                let _stream = std::net::TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
                std::thread::sleep(Duration::from_millis(500));
                unsafe { ksign_pairing_cancel(addr as *mut KsignPairingSession) };
            });
        }
        unsafe {
            let session = ksign_pairing_new();
            let name = CString::new("Ksign test").unwrap();
            let mut record = std::ptr::null_mut();
            let started = std::time::Instant::now();
            let error = ksign_pairing_run(session, name.as_ptr(), Some(poke_then_cancel), session.cast(), &mut record);
            assert!(!error.is_null());
            let message = CStr::from_ptr((*error).message).to_str().unwrap().to_owned();
            assert!(message.contains("cancelled"), "unexpected error: {message}");
            assert!(started.elapsed() >= Duration::from_millis(400), "the stray connection ended the run early");
            crate::idevice_error_free(error);
            ksign_pairing_free(session);
        }
    }

    #[test]
    fn only_local_peers_are_accepted() {
        let local = ["127.0.0.1", "10.1.2.3", "172.16.0.9", "172.31.255.1", "192.168.1.20", "169.254.4.4", "100.64.0.1", "100.127.9.9",
                     "::1", "fe80::1", "fd12:3456::1", "::ffff:192.168.0.5"];
        let remote = ["8.8.8.8", "172.32.0.1", "100.63.0.1", "100.128.0.1", "1.1.1.1", "2606:4700::1111", "::ffff:8.8.8.8"];
        for ip in local { assert!(is_local_peer(ip.parse().unwrap()), "{ip} should be local"); }
        for ip in remote { assert!(!is_local_peer(ip.parse().unwrap()), "{ip} should be remote"); }
    }

    #[test]
    fn timeout_is_defaulted_and_capped() {
        assert_eq!(clamp_timeout(0), DEFAULT_TIMEOUT_SECS);
        assert_eq!(clamp_timeout(30), 30);
        assert_eq!(clamp_timeout(86_400), MAX_TIMEOUT_SECS);
    }

    #[test]
    fn unreadable_identity_is_ignored() {
        assert!(parse_identity("not json").is_none());
        assert!(parse_identity(r#"{"pairing_plist":"x","host_alt_irk":[1,2,3]}"#).is_none());
        assert!(parse_identity(r#"{"host_alt_irk":[]}"#).is_none());
    }

    #[test]
    fn freeing_a_record_does_not_crash() {
        let record = CString::new("secret-credentials").unwrap().into_raw();
        unsafe { ksign_pairing_string_free(record) };
        unsafe { ksign_pairing_string_free(std::ptr::null_mut()) };
    }
}
