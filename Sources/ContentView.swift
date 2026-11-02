import SwiftUI

struct ContentView: View {
    @StateObject private var pairing = PairingController.shared
    @ObservedObject private var log = LogBus.shared

    @State private var pairingPath: String?
    @State private var targetPath = "/var/mobile/Library/SpringBoard"
    @State private var bundleID = "com.apple.PosterBoard"
    @State private var readPath = "/var/mobile/Library/SpringBoard/IconState.plist"
    @State private var output = ""
    @State private var iface = "—"
    @State private var apps: [AppTarget] = AppTarget.defaults
    @State private var resolving = false
    @State private var progressText = ""

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
                    Labeled("网卡：\(iface)")
                    Button("刷新网卡") { refreshIfaces() }
                }

                Section(header: Text("2 · App 容器（写前先打开一次「图书」App）")) {
                    Button(resolving ? "解析中…" : "全部解析") { resolveAll() }
                        .disabled(resolving || pairingPath == nil)
                    if !progressText.isEmpty {
                        Text(progressText).font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    ForEach(apps) { app in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.id).font(.system(size: 11, design: .monospaced))
                                Text(app.path ?? (app.resolved ? "未找到" : "—"))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(app.path == nil ? .secondary : .green)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            if let p = app.path {
                                Button("设为目标") {
                                    targetPath = p + "/Documents"
                                    output = "目标已设为：\(targetPath)"
                                }
                                .font(.caption)
                            }
                        }
                    }
                }

                Section(header: Text("3 · 写入")) {
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

                Section(header: Text("4 · 读取（move-out → read → move-back）")) {
                    Text("⚠️ 目标文件会被临时搬走再搬回，目标 App 正在运行时可能损坏数据")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    HStack {
                        TextField("设备文件绝对路径", text: $readPath)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.system(size: 10, design: .monospaced))
                    }
                    Button("读取到 App 沙盒") { doPull() }
                }

                Section(header: Text("5 · 单个 Bundle ID")) {
                    TextField("Bundle ID", text: $bundleID)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(.footnote, design: .monospaced))
                    Button("解析容器路径") { doContainer() }
                    Button("扫描 ContainerManager 参数空间") {
                        output = "扫描中…（约 500 组参数，可能要 1 分钟）"
                        let target = bundleID
                        MCMScan.run(targetBundle: target) { line in
                            DispatchQueue.main.async { output += "\n" + line }
                        }
                    }
                }

                Section(header: Text("输出")) {
                    Text(output.isEmpty ? "—" : output)
                        .font(.system(size: 11, design: .monospaced))
                }

                Section(header: HStack {
                    Text("引擎日志")
                    Spacer()
                    Button("复制") { UIPasteboard.general.string = log.text() }
                        .font(.caption)
                    Button("清空") { log.clear() }
                        .font(.caption)
                        .foregroundColor(.red)
                }) {
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
            pairing.pairingStatus = "已配对（凭据来自本地 / Keychain）"
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

    private func resolveAll() {
        guard let p = pairingPath else { output = "先配对"; return }
        resolving = true
        progressText = "0/\(apps.count)"
        var list = apps
        for i in list.indices { list[i].path = nil; list[i].resolved = false }
        apps = list
        Engine.shared.resolveAll(pairing: p, ids: apps.map(\.id)) { idx, _, path in
            if idx < apps.count {
                apps[idx].path = path
                apps[idx].resolved = true
                progressText = "\(idx + 1)/\(apps.count)"
            }
        } done: {
            resolving = false
            let found = apps.filter { $0.path != nil }.count
            progressText = "完成：\(found)/\(apps.count) 个已安装"
            output = "解析完成，找到 \(found) 个 App 容器"
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

    private func doPull() {
        guard let p = pairingPath else { output = "先配对"; return }
        output = "读取中（搬出 → 读 → 搬回）…"
        Engine.shared.pull(pairing: p, devicePath: readPath) { output = $0 }
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
