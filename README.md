# FilzaLite

基于 AirCard 的 `AirliftFFI`（AirTraffic / ATAirlock 沙盒逃逸）做的文件工具。

## 已验证（iOS 27.0.1，无越狱，免费签名，无需 Mac）

| 能力 | 状态 |
|---|---|
| 设备自配对（Bonjour + 设置里输 PIN） | ✅ |
| RSD 隧道（85 个服务） | ✅ |
| AFC / StreamingZip | ✅ |
| atc + Grappa 授权 | ✅ |
| 沙盒外写入（SpringBoard 目录，逐字节回读一致） | ✅ |
| **写入第三方 App 容器（微信 Documents）** | ✅ |
| 读文件 / 列目录 | ❌ 待实现 |

## 构建

推 GitHub 后 Actions 自动出 `FilzaLite.ipa`（未签名，Sideloadly 安装）。
CI 现场 clone `Mak5er/AirCard-iOS` 取 `AirliftFFI.xcframework`。

## 使用前提

1. iOS **27.0.1**（27.2 beta 3 起该漏洞已修），关闭自动更新
2. 装 LocalDevVPN 并开回环模式（utun4 = 10.7.x.x）
3. 打开一次「图书」App，否则 atc 会停在 `ReadyForSync not observed`

## B 档：任意文件读（待实现）

### 目标接口

```c
int32_t al_exploit_pull(const char *pairing_path,
                        const char *device_path,   // 绝对路径
                        const char *local_out,     // 写入沙盒内文件
                        ALLogCallback log_cb, void *ctx,
                        char **out_error);
```

### 实现要点（照 `exploit.rs` 的 canary 流程改）

canary 的三跳已经在 `exploit.rs:939-948` 写死：

```rust
identifiers[0] = "../../{source}/p0/p1/p2/link";  // 符号链接
destinations[0] = link_destination;               // 搬进 Media
identifiers[1] = "../../{source}/payload";
destinations[1] = "{link_destination}/{leaf}";    // 经链接解析落到目标目录
identifiers[2] = posix_rel(target_path, AIRLOCK_ROOT);
destinations[2] = recovered;                      // 从目标目录搬回 Media
```

pull 复用第一跳（拿到指向目标目录的符号链接）+ 第二跳反向：

1. **Sync A**：`link → link_destination`；`identifier = posix_rel(device_path, AIRLOCK_ROOT)`，
   `destination = recovered`（Media 内）
2. **AFC** 读 `recovered` → 落盘到 `local_out`
3. **Sync B**：`identifier = posix_rel(recovered, AIRLOCK_ROOT)`，
   `destination = "{link_destination}/{filename}"`（字符串在 Media 内，解析后回原位）
4. 清理 Media 残留 + 恢复 Books.plist

### 风险与保护

- 是 **move 不是 copy**：中途失败 = 文件留在 Media、原位置丢失
- 必须做 **哈希校验**：搬出后算 hash → 搬回后再搬出一次算 hash → 一致才算成功
- 目标 App 运行中会持有句柄，move 走可能导致该 App 崩溃或库损坏
- B 档上线时默认要求：先 `al_device_respring` 结束前台进程，或至少提示用户手动杀掉目标 App

### 分三步落地

1. CI 加 rustup + `aarch64-apple-ios`，先只验证 `cargo build --release` 能过（不改行为）
2. `exploit.rs` 加 `exploit_pull`，`lib.rs` / `airlift.h` 加导出
3. Swift 端加「读文件」入口 + 哈希校验展示
