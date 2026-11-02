import Foundation
import AirliftFFI

/// 全局日志出口，UI 订阅它
final class LogBus: ObservableObject {
    static let shared = LogBus()
    @Published var lines: [String] = []
    func append(_ s: String) {
        DispatchQueue.main.async {
            self.lines.append(s)
            if self.lines.count > 400 { self.lines.removeFirst(100) }
        }
    }
    func clear() { lines.removeAll() }
}

/// AirliftFFI 的 Swift 封装
final class Engine {
    static let shared = Engine()
    private init() {}

    private let onLog: ALLogCallback = { _, msg in
        guard let msg = msg else { return }
        LogBus.shared.append(String(cString: msg))
    }

    /// 对任意绝对路径做金丝雀写入校验
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

    /// 把本地目录里的文件写进设备任意目录
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

    /// bundle id -> 数据容器路径
    func container(pairing: String, bundleID: String, done: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
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
            DispatchQueue.main.async { done(rc == 0 && !c.isEmpty ? c : nil) }
        }
    }

    func respring(pairing: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var outErr: UnsafeMutablePointer<CChar>? = nil
            pairing.withCString { p in
                _ = al_device_respring(p, self.onLog, nil, &outErr)
            }
            if let p = outErr { al_string_free(p) }
        }
    }

    /// 在 App 沙盒里造一个待写入的目录
    func stagingDir() -> String {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("stage")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }
}
