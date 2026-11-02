// FilzaLite patch: FFI 导出，追加到 rust-core/src/lib.rs 末尾

#[no_mangle]
pub unsafe extern "C" fn al_exploit_pull(
    pairing_path: *const c_char,
    device_path: *const c_char,
    local_out: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_sha256: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    exploit::pull(pairing_path, device_path, local_out, log_cb, ctx, out_sha256, out_error)
}

#[no_mangle]
pub unsafe extern "C" fn al_house_arrest_probe(
    pairing_path: *const c_char,
    bundle_id: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    exploit::ha_probe(pairing_path, bundle_id, log_cb, ctx, out_error)
}
