// FilzaLite: house_arrest 探测 v2 —— 三变体一次跑完
// 追加到 rust-core/src/exploit.rs 末尾

pub unsafe fn ha_probe(
    pairing_path: *const c_char,
    bundle_id: *const c_char,
    log_cb: ALLogCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing = opt_str(pairing_path, "");
    let bundle = opt_str(bundle_id, "");
    let ctx_usize = ctx as usize;

    let res = crate::ffi_util::run_with_large_stack("al_house_arrest_probe", move || {
        let logger = Logger { cb: log_cb, ctx: ctx_usize as *mut c_void };
        idevice_ffi::run_sync_local(ha_probe_impl(pairing, bundle, &logger))
    });

    match res {
        Ok(Ok(msg)) => { if !out_error.is_null() { *out_error = cstr(msg); } 0 }
        Ok(Err(e))   => { if !out_error.is_null() { *out_error = cstr(e); } 1 }
        Err(p)       => { if !out_error.is_null() { *out_error = cstr(p); } 1 }
    }
}

async fn ha_probe_one(
    tunnel: &mut AppDeviceTunnel,
    cmd: &str,
    bundle: &str,
    extra_client: bool,
    logger: &Logger,
) -> String {
    let svc = "com.apple.mobile.house_arrest";
    let mut s = match tunnel.connect_service(svc, logger).await {
        Ok(x) => x,
        Err(e) => return format!("[{cmd}] connect failed: {e}"),
    };

    let mut d = plist::Dictionary::new();
    d.insert("Command".into(), plist::Value::String(cmd.into()));
    d.insert("Identifier".into(), plist::Value::String(bundle.into()));
    if extra_client {
        d.insert("Client".into(), plist::Value::String("FilzaLite".into()));
    }
    let mut buf = Vec::new();
    if plist::to_writer_binary(&mut buf, &plist::Value::Dictionary(d)).is_err() {
        return format!("[{cmd}] encode failed");
    }

    if s.write_all(&(buf.len() as u32).to_be_bytes()).await.is_err() { return format!("[{cmd}] write len failed"); }
    if s.write_all(&buf).await.is_err() { return format!("[{cmd}] write body failed"); }
    if s.flush().await.is_err() { return format!("[{cmd}] flush failed"); }

    let mut lb = [0u8; 4];
    if s.read_exact(&mut lb).await.is_err() { return format!("[{cmd}] no response"); }
    let n = u32::from_be_bytes(lb) as usize;
    if n == 0 || n > 1 << 20 { return format!("[{cmd}] bad length {n}"); }
    let mut body = vec![0u8; n];
    if s.read_exact(&mut body).await.is_err() { return format!("[{cmd}] short body"); }

    match plist::Value::from_reader(std::io::Cursor::new(&body)) {
        Ok(v) => format!("[{cmd}] {v:?}"),
        Err(_) => format!("[{cmd}] <非 plist {} 字节>", body.len()),
    }
}

async fn ha_probe_impl(
    pairing_path: String,
    bundle_id: String,
    logger: &Logger,
) -> Result<String, String> {
    logger.log(format!("ha: v2 probing {bundle_id}"));
    let pairing_bytes = std::fs::read(&pairing_path).map_err(|e| format!("读取配对文件失败: {e}"))?;
    let mut tunnel = connect_tunnel(&pairing_bytes, logger).await?;

    let mut out = Vec::new();
    for (cmd, client) in [
        ("VendDocuments", true),
        ("VendContainer", true),
        ("VendContainer", false),
    ] {
        let r = ha_probe_one(&mut tunnel, cmd, &bundle_id, client, logger).await;
        logger.log(format!("ha: {r}"));
        out.push(r);
    }

    let joined = out.join("\n");
    if joined.contains("Prohibited") {
        return Err(format!("❌ 被拒（Prohibited）\n{joined}"));
    }
    if joined.contains("InstallationLookupFailed") && !joined.contains("Status") {
        return Err(format!("❌ 全部 InstallationLookupFailed（查库失败）\n{joined}"));
    }
    Ok(format!("✅ 有变体通过，检查回包\n{joined}"))
}
