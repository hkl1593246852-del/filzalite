import SwiftUI

struct ContentView: View {
    @StateObject private var pairing = PairingController.shared
    @ObservedObject private var log = LogBus.shared

    @State private var pairingPath: String?
    @State private var targetPath = "/var/mobile/Library/SpringBoard"
    @State private var bundleID = "com.apple.PosterBoard"
    @State private var output = ""
    @State private var iface = "—"

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("1 · 配对")) {
                    Text(pairing.pairingStatus).font(.footnote)
                    if let pin = pairing.pairingPIN {
                        Text("PIN \(pin)").font(.title2).bold()
                    }
                    Button(pairing.running ? "配对中…" : "开始配对") {
                        Task { await doPair() }
                    }
                    .disabled(pairing.running)
                    if pairingPath != nil {
                        Text("配对文件就绪").foregroundColor(.green).font(.footnote)
                    }
                }

                Section(header: Text("诊断")) {
                    Labeled(pairing.hostReady ? "✅ 主机已就绪" : "⏳ 主机未就绪")
                    Labeled("广播：\(pairing.publishState)")
                    if !pairing.lastError.isEmpty { Labeled("错误：\(pairing.lastError)") }
                    if !pairing.serviceIDShown.isEmpty { Labeled("service：\(pairing.serviceIDShown)") }
                    Labeled("网卡：\(iface)")
                    Button("刷新网卡") { refreshIfaces() }
                }

                Section(header: Text("2 · 写任意路径")) {
                    TextField("目标目录（绝对路径）", text: $targetPath)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(.footnote, design: .monospaced))
                    Button("金丝雀测试（只验证可写）") { doCanary() }
                    Button("把测试文件写进该目录") { doWrite() }
                    Button("Respring") {
                        if let p = pairingPath { Engine.shared.respring(pairing: p) }
                    }
                }

                Section(header: Text("3 · App 容器")) {
                    TextField("Bundle ID", text: $bundleID)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(.footnote, design: .monospaced))
                    Button("解析容器路径") { doContainer() }
                }

                Section(header: Text("输出")) {
                    Text(output.isEmpty ? "—" : output)
                        .font(.system(size: 11, design: .monospaced))
                }

                Section(header: Text("引擎日志")) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(log.lines.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(size: 9, design: .monospaced))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 200)
                }
            }
            .navigationTitle("FilzaLite")
            .onAppear {
                loadExisting()
                refreshIfaces()
            }
        }
        .navigationViewStyle(.stack)
    }

    private func refreshIfaces() {
        let s = NetworkStatus.summarize(deviceIP: "10.7.0.1")
        iface = "vpn=\(s.vpn) wifi=\(s.wifi) | \(s.detail)"
    }

    private func loadExisting() {
        let p = PairingController.pairingFilePath()
        let size = (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int) ?? 0
        if size > 0 {
            pairingPath = p
            output = "已有配对文件：\(p) (\(size) B)"
        }
    }

    private func doPair() async {
        output = "配对中…"
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        do {
            let p = try await pairing.startAndWait()
            pairingPath = p
            output = "配对成功：\(p)"
        } catch {
            output = "配对失败：\(error.localizedDescription)"
        }
    }

    private func doCanary() {
        guard let p = pairingPath else { output = "先配对"; return }
        output = "金丝雀测试中…"
        Engine.shared.canary(pairing: p, target: targetPath) { output = $0 }
    }

    private func doWrite() {
        guard let p = pairingPath else { output = "先配对"; return }
        let dir = Engine.shared.stagingDir()
        let name = "filzalite-probe-\(Int(Date().timeIntervalSince1970)).txt"
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
        do {
            try "filzalite probe\n\(Date())\n".write(to: url, atomically: true, encoding: .utf8)
        } catch {
            output = "写本地暂存失败：\(error.localizedDescription)"
            return
        }
        output = "写入中：\(name) -> \(targetPath)"
        Engine.shared.writeDir(pairing: p, sourceDir: dir, targetDir: targetPath) { output = $0 }
    }

    private func doContainer() {
        guard let p = pairingPath else { output = "先配对"; return }
        output = "解析中…"
        Engine.shared.container(pairing: p, bundleID: bundleID) { path in
            output = path ?? "未解析到容器（bundle id 可能不存在）"
        }
    }
}

private struct Labeled: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.system(size: 11, design: .monospaced))
    }
}
