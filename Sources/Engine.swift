import Foundation
import AirliftFFI

/// 全局日志出口，UI 订阅它；同时落盘到 Documents/filzalite.log
final class LogBus: ObservableObject {
    static let shared = LogBus()
    @Published var lines: [String] = []

    private lazy var logURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("filzalite.log")
    }()

    private let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func append(_ s: String) {
        let line = "[\(df.string(from: Date()))] \(s)"
        DispatchQueue.main.async {
            self.lines.append(line)
            if self.lines.count > 600 { self.lines.removeFirst(200) }
        }
        // 落盘
        if let data = (line + "\n").data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: logURL) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    func text() -> String { lines.joined(separator: "\n") }

    func filePath() -> String { logURL.path }

    func clear() {
        lines.removeAll()
        try? FileManager.default.removeItem(at: logURL)
    }
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

    func stagingDir() -> String {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("stage")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }
}
