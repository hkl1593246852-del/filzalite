# al_exploit_pull 实现规格（读原语）

目标：把设备上任意绝对路径的文件「搬出 → 读出 → 搬回」，落盘到 App 沙盒。

## 已确认的代码事实（upstream: Mak5er/AirCard-iOS @ main）

| 位置 | 内容 |
|---|---|
| `rust-core/src/exploit.rs:31-35` | `SOURCE_PREFIX/LINK_PREFIX/RECOVERED_PREFIX/CANARY_PREFIX/AIRLOCK_ROOT` |
| `exploit.rs:939-948` | canary 的三跳 identifiers / destinations（**直接照抄结构**） |
| `exploit.rs:961-1005` | StreamingZip 上传流程（MediaSubdir + archive + 读响应） |
| `exploit.rs:1087-1142` | atc 握手：SyncAllowed → HostInfo（含 Grappa）→ RequestingSync |
| `exploit.rs:1144-1185` | 等 ReadyForSync，处理 Ping/Pong、SyncFailed(非致命) |
| `exploit.rs:1201-1261` | FinishedSyncingMetadata → 等 AssetManifest → 逐条 FileComplete |
| `exploit.rs:1268-1300` | AFC readback + 清理 + 恢复 Books.plist |
| `exploit.rs:2428` | `build_archive(&target_dir, &payload) -> Result<Vec<u8>>`（内含相对符号链接） |
| `exploit.rs:2640` | `build_books_plist(&identifiers) -> Result<Vec<u8>>`（Persistent ID 原样写入，**无校验**） |
| `exploit.rs:2665` | `posix_rel(path, base)` 相对路径计算 |
| `exploit.rs:2686` | `random_hex(n)` |

## canary 的三跳（读的模板）

```rust
let source = format!("{}{}", SOURCE_PREFIX, token);
let link_destination = format!("{}{}", LINK_PREFIX, token);
let recovered = format!("{}{}", RECOVERED_PREFIX, token);

identifiers[0] = format!("../../{}/p0/p1/p2/link", source);   // 符号链接
destinations[0] = link_destination;                            // 搬到 Media

identifiers[1] = format!("../../{}/payload", source);
destinations[1] = format!("{}/{}", link_destination, leaf);    // 经链接落到目标目录

identifiers[2] = posix_rel(&target_path, AIRLOCK_ROOT);        // 目标目录里的真实路径
destinations[2] = recovered;                                   // 搬回 Media 供 AFC 读
```

关键性质：**第 3 跳已经能读出任意文件**，只是读完就删了（`afc.remove(&recovered)`）。
读原语 = 把「读完删除」换成「读完搬回原位」。

## pull 算法

输入：`pairing_path`、`device_path`、`local_out`。

1. `parent_dir = dirname(device_path)`，`filename = basename(device_path)`
2. 建 staging：`build_archive(&parent_dir, &payload)` + `build_books_plist(&[id_out, id_back?])`
   - 至少需要 `identifiers[0] = link_identifier`（建立指向 parent_dir 的链接）
3. **Sync A**（一次 atc 会话，两条 FileComplete）：
   - `link_identifier → link_destination`
   - `posix_rel(device_path, AIRLOCK_ROOT) → recovered`
4. `afc.open(recovered).read_entire()` → 写 `local_out`，记录 sha256
5. **Sync B**（新会话，一条 FileComplete）：
   - `posix_rel(recovered, AIRLOCK_ROOT) → format!("{}/{}", link_destination, filename)`
6. 校验：再次 Sync A 单向搬出 → 读 → 与第 4 步哈希比对 → 一致则成功，然后 Sync B 搬回
7. 清理：`afc.remove_all(link_destination)`、`afc.remove(recovered)`、`afc.remove_all(source)`
8. 无论成败都恢复 Books.plist（`original_books_plist`）

## FFI

```c
int32_t al_exploit_pull(const char *pairing_path,
                        const char *device_path,
                        const char *local_out,
                        ALLogCallback log_cb, void *ctx,
                        char **out_sha256, char **out_error);
```

`lib.rs` 里照 `al_exploit_write_dir` 的 `catch_unwind` 包装写一遍。

## 风险与硬性保护

- 是 **move 不是 copy**：搬回失败 = 文件留在 Media、原位置丢失
- 目标 App 正在运行 → 文件被独占，move 会造成该 App 崩溃或数据库损坏
- 上线必须加：① 目标 App 进程检测/提示 ② 搬回后哈希校验 ③ 失败时把留下的文件路径报给用户
- 禁止对 `/var/mobile/Library/SMS`、`Library/Keychain` 之类核心库默认开放

## CI 侧

`rust-check.yml` 已验证 `cargo build --release --target aarch64-apple-ios` 可过（run 41397356880）。
正式构建时把 `build.yml` 改成：

```yaml
- run: |
    source "$HOME/.cargo/env"
    cd vendor/AirCard/rust-core && cargo build --release --target aarch64-apple-ios
- run: |
    # 用自编译的 .a 替换 xcframework 里的预编译库
    cp target/aarch64-apple-ios/release/libairlift_ffi.a \
       ../../AirliftFFI.xcframework/ios-arm64/libairlift_ffi.a
```

## UI（可视化）

```
[5 · 浏览]
  路径输入 + [读取] [列目录] [上一级]
  列表：文件夹 / 文件 + 大小
  点文件 → 文本 / 十六进制双视图
  状态条：move-out → read → move-back 校验中（红色表示哈希不一致）
```
