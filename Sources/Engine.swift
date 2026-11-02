import Foundation
import AirliftFFI

/// 我们自己编进 libairlift_ffi.a 的函数（不在预编译 xcframework 头里）
typealias CLogCB = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void

@_silgen_name("al_exploit_pull")
private func al_exploit_pull(_ pairing: UnsafePointer<CChar>?,
                             _ device: UnsafePointer<CChar>?,
                             _ localOut: UnsafePointer<CChar>?,
                             _ cb: CLogCB?,
                             _ ctx: UnsafeMutableRawPointer?,
                             _ outSha: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                             _ outErr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32

/// 全局日志出口，UI 订阅它；同时落盘到 Documents/filzalite.log
final class LogBus: ObservableObject {
    static let shared = LogBus()
    @Published var lines: [String] = []

    private lazy var logURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("filzalite.log")
    }()

    private let df: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    func append(_ s: String) {
        let line = "[\(df.string(from: Date()))] \(s)"
        DispatchQueue.main.async {
            self.lines.append(line)
            if self.lines.count > 600 { self.lines.removeFirst(200) }
        }
        if let data = (line + "\n").data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: logURL) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    func text() -> String { lines.joined(separator: "\n") }
    func clear() {
        lines.removeAll()
        try? FileManager.default.removeItem(at: logURL)
    }
}

/// 常用 App 的 bundle id
struct AppTarget: Identifiable, Equatable {
    let id: String
    var path: String?
    var resolved: Bool = false

    static let defaults: [AppTarget] = [
        AppTarget(id: "com.apple.PosterBoard"),
        AppTarget(id: "com.apple.mobilesafari"),
        AppTarget(id: "com.apple.MobileSMS"),
        AppTarget(id: "com.apple.mobilenotes"),
        AppTarget(id: "com.apple.Preferences"),
        AppTarget(id: "com.apple.DocumentsApp"),
        AppTarget(id: "com.apple.MobileAddressBook"),
        AppTarget(id: "com.apple.mobilemail"),
        AppTarget(id: "com.apple.mobilecal"),
        AppTarget(id: "com.apple.Health"),
        AppTarget(id: "com.apple.music"),
        AppTarget(id: "com.apple.AppStore"),
        AppTarget(id: "com.apple.shortcuts"),
        AppTarget(id: "com.apple.camera"),
        AppTarget(id: "com.tencent.xin"),
        AppTarget(id: "com.tencent.mqq"),
        AppTarget(id: "com.alipay.iphoneclient"),
        AppTarget(id: "com.taobao.taobao4iphone"),
        AppTarget(id: "com.ss.iphone.ugc.Aweme"),
        AppTarget(id: "com.jingdong.app.mall"),
        AppTarget(id: "com.sina.weibo"),
        AppTarget(id: "com.zhihu.ios"),
        AppTarget(id: "com.netease.cloudmusic"),
        AppTarget(id: "com.xingin.discover"),
    ]
}

/// AirliftFFI 的 Swift 封装
final class Engine {
    static let shared = Engine()
    private init() {}

    private let onLog: ALLogCallback = { _, msg in
        guard let msg = msg else { return }
        LogBus.shared.append(String(cString: msg))
    }

    func canary(pairing: String, target: String, done: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var outJSON: UnsafeMutablePointer<CChar>? = nil
            var outErr: UnsafeMutablePointer<CChar>? = nil
            let rc = target.withCString { t in
                pairing.withCString { p in
                    al_exploit_run(p, t, self.onLog, nil, &outJSON, &outErr)
                }
            }
            let json = outJSON.map { String(cString: $0) } ?? ""
            let err = outErr.map { String(cString: $0) } ?? ""
            if let p = outJSON { al_string_free(p) }
            if let p = outErr { al_string_free(p) }
            let text = rc == 0 ? "OK (rc=0)\n\(json)" : "FAILED (rc=\(rc))\n\(err)"
            DispatchQueue.main.async { done(text) }
        }
    }

    func writeDir(pairing: String, sourceDir: String, targetDir: String,
                  done: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var outErr: UnsafeMutablePointer<CChar>? = nil
            let rc = targetDir.withCString { t in
                sourceDir.withCString { s in
                    pairing.withCString { p in
                        al_exploit_write_dir(p, s, t, self.onLog, nil, &outErr)
                    }
                }
            }
            let err = outErr.map { String(cString: $0) } ?? ""
            if let p = outErr { al_string_free(p) }
            let text = rc == 0 ? "WRITE OK -> \(targetDir)" : "WRITE FAILED (rc=\(rc)) \(err)"
            DispatchQueue.main.async { done(text) }
        }
    }

    /// 同步版容器解析（内部用）
    private func containerSync(pairing: String, bundleID: String) -> String? {
        var outC: UnsafeMutablePointer<CChar>? = nil
        var outErr: UnsafeMutablePointer<CChar>? = nil
        let rc = bundleID.withCString { b in
            pairing.withCString { p in
                al_find_app_container(p, b, self.onLog, nil, &outC, &outErr)
            }
        }
        let c = outC.map { String(cString: $0) } ?? ""
        if let p = outC { al_string_free(p) }
        if let p = outErr { al_string_free(p) }
        return (rc == 0 && !c.isEmpty) ? c : nil
    }

    func container(pairing: String, bundleID: String, done: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let c = self.containerSync(pairing: pairing, bundleID: bundleID)
            DispatchQueue.main.async { done(c) }
        }
    }

    /// 批量解析，逐个回调
    func resolveAll(pairing: String,
                    ids: [String],
                    progress: @escaping (Int, String, String?) -> Void,
                    done: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            for (i, id) in ids.enumerated() {
                let path = self.containerSync(pairing: pairing, bundleID: id)
                DispatchQueue.main.async { progress(i, id, path) }
            }
            DispatchQueue.main.async { done() }
        }
    }

    /// 把设备上的文件读到 App 沙盒（move-out → read → move-back）
    func pull(pairing: String, devicePath: String, done: @escaping (String) -> Void) {
        let name = (devicePath as NSString).lastPathComponent
        let dest = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name.isEmpty ? "pulled.bin" : name)
        let cb: CLogCB = { _, msg in
            guard let msg = msg else { return }
            LogBus.shared.append(String(cString: msg))
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var sha: UnsafeMutablePointer<CChar>? = nil
            var err: UnsafeMutablePointer<CChar>? = nil
            let rc = devicePath.withCString { d in
                pairing.withCString { p in
                    dest.path.withCString { o in
                        al_exploit_pull(p, d, o, cb, nil, &sha, &err)
                    }
                }
            }
            let s = sha.map { String(cString: $0) } ?? ""
            let e = err.map { String(cString: $0) } ?? ""
            if let p = sha { al_string_free(p) }
            if let p = err { al_string_free(p) }
            var msg = rc == 0 ? "读取成功\nsha256=\(s)\n本地文件：\(dest.path)"
                              : "读取失败 (rc=\(rc))\n\(e)"
            if let data = try? Data(contentsOf: dest), data.count < 4096,
               let text = String(data: data, encoding: .utf8) {
                msg += "\n\n预览：\n" + String(text.prefix(1200))
            }
            DispatchQueue.main.async { done(msg) }
        }
    }

    func respring(pairing: String) {        DispatchQueue.global(qos: .userInitiated).async {
            var outErr: UnsafeMutablePointer<CChar>? = nil
            pairing.withCString { p in
                _ = al_device_respring(p, self.onLog, nil, &outErr)
            }
            if let p = outErr { al_string_free(p) }
        }
    }

    func stagingDir() -> String {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("stage")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }
}
