# FilzaLite

基于 AirCard 的 `AirliftFFI`（AirTraffic / ATAirlock 沙盒逃逸）做的文件写入工具骨架。

## 当前能力（v0.1）

| 功能 | 状态 |
|---|---|
| 设备自配对（Bonjour + 设置里输 PIN，不需要 Mac） | ✅ |
| 金丝雀写入验证（任意绝对路径） | ✅ |
| 把本地文件写进任意设备目录 `al_exploit_write_dir` | ✅ |
| bundle id → 数据容器路径 `al_find_app_container` | ✅ |
| Respring | ✅ |
| **读文件 / 列目录** | ❌ 未实现，需要给 Rust 核心加 `al_exploit_pull` |

## 构建

推到 GitHub 后自动跑 Actions，产物 `FilzaLite.ipa`（未签名，用 Sideloadly 装）。

CI 会现场 clone `Mak5er/AirCard-iOS` 拿 `AirliftFFI.xcframework`，不把 133 MB 塞进本仓库。

## 使用前

1. 设备停在 **iOS 27.0.1**（27.2 beta 3 起该漏洞已修），关掉自动更新
2. 装 LocalDevVPN 并开启回环模式（提供 10.7.0.1 路由）
3. 打开 App → 开始配对 → 去 设置 › 隐私与安全 › 开发者模式 › 与 FilzaLite 配对 → 输入 PIN

## 第二阶段（读）

`al_exploit_pull` 的实现思路：把 Books.plist 的 `Persistent ID` 填成
`../../../../Library/SMS/sms.db` 这样的穿越串当**源路径**，让 ATAirlock 把目标文件
move 进 `/var/mobile/Media/`，再用 AFC 读出来，最后 move 回原位。

注意：这是 move 不是 copy，失败会丢文件，实现时必须先校验再搬回。

## 免责

仅用于自有设备的研究。漏洞已在 27.2 修复。
