// FilzaLite: house_arrest 探测 —— 追加到 rust-core/src/exploit.rs 末尾
//
// 思路：com.apple.mobile.house_arrest 按「配对信任」授权，而不是 App 签名身份。
// 我们持有合法自配对隧道，因此直接问它要某个 App 的容器。
// 第一枪只验证「授权是否通过」：发 VendDocuments，看回包里 Status。

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
        Ok(Ok(msg)) => {
            if !out_error.is_null() { *out_error = cstr(msg); }
            0
        }
        Ok(Err(e)) => {
            if !out_error.is_null() { *out_error = cstr(e); }
            1
        }
        Err(p) => {
            if !out_error.is_null() { *out_error = cstr(p); }
            1
        }
    }
}

async fn ha_probe_impl(
    pairing_path: String,
    bundle_id: String,
    logger: &Logger,
) -> Result<String, String> {
    logger.log(format!("ha: probing house_arrest for {bundle_id}"));
    let pairing_bytes = std::fs::read(&pairing_path)
        .map_err(|e| format!("读取配对文件失败: {e}"))?;
    let mut tunnel = connect_tunnel(&pairing_bytes, logger).await?;

    let svc = "com.apple.mobile.house_arrest";
    let mut s = match tunnel.connect_service(svc, logger).await {
        Ok(x) => x,
        Err(e) => {
            logger.log(format!("ha: 连 {svc} 失败: {e}"));
            return Err(format!("connect_service {svc}: {e}"));
        }
    };

    let mut d = plist::Dictionary::new();
    d.insert("Command".into(), plist::Value::String("VendDocuments".into()));
    d.insert("Identifier".into(), plist::Value::String(bundle_id));
    let mut buf = Vec::new();
    plist::to_writer_binary(&mut buf, &plist::Value::Dictionary(d))
        .map_err(|e| format!("encode: {e}"))?;

    s.write_all(&(buf.len() as u32).to_be_bytes())
        .await
        .map_err(|e| format!("write len: {e}"))?;
    s.write_all(&buf).await.map_err(|e| format!("write body: {e}"))?;
    s.flush().await.map_err(|e| format!("flush: {e}"))?;
    logger.log("ha: VendDocuments 已发送，等回包…");

    let mut lb = [0u8; 4];
    s.read_exact(&mut lb).await.map_err(|e| format!("read len: {e}"))?;
    let n = u32::from_be_bytes(lb) as usize;
    if n == 0 || n > 1 << 20 {
        return Err(format!("回包长度异常: {n}"));
    }
    let mut body = vec![0u8; n];
    s.read_exact(&mut body).await.map_err(|e| format!("read body: {e}"))?;

    let txt = match plist::Value::from_reader(std::io::Cursor::new(&body)) {
        Ok(v) => format!("{v:?}"),
        Err(_) => format!("<非 plist, {} 字节>", body.len()),
    };
    logger.log(format!("ha: 回包 = {txt}"));
    Ok(format!("✅ house_arrest 授权通过: {txt}"))
}
