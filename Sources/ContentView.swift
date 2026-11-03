import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var pairing = PairingController.shared
    @ObservedObject private var log = LogBus.shared

    @State private var pairingPath: String?
    @State private var targetPath = "/var/mobile/Library/SpringBoard"
    @State private var bundleID = "com.apple.PosterBoard"
    @State private var readPath = "/var/mobile/Library/SpringBoard/IconState.plist"
    @State private var listFilter = "Container"
    @State private var showImporter = false
    @State private var chunkOffset = "0"
    @State private var chunkSize = "67108864"
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
                    Button("导入文件并写入目标目录") { showImporter = true }
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
                    TextField("过滤关键字（留空显示全部）", text: $listFilter)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(size: 11, design: .monospaced))
                    Button("列目录（普通读取）") { doListPlain() }
                    Button("扫子缓存地址范围") { doScanSubcaches() }
                    HStack {
                        TextField("偏移", text: $chunkOffset)
                            .font(.system(size: 11, design: .monospaced))
                        TextField("长度", text: $chunkSize)
                            .font(.system(size: 11, design: .monospaced))
                        Button("分段读取") { doChunkRead() }
                    }
                }

                Section(header: Text("5 · 单个 Bundle ID")) {
                    TextField("Bundle ID", text: $bundleID)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(.footnote, design: .monospaced))
                    Button("解析容器路径") { doContainer() }
                    Button("探测 house_arrest 授权") { doHA() }
                    Button("读取该 App 的偏好设置") { doReadPrefs() }
                    Button("扫描 ContainerManager 参数空间") {
                        output = "扫描中…（约 500 组参数，可能要 1 分钟）"
                        let target = bundleID
                        MCMScan.run(targetBundle: target) { line in
                            DispatchQueue.main.async { output += "\n" + line }
                        }
                    }
                }

                Section(header: HStack {
                    Text("输出")
                    Spacer()
                    Button("复制") { UIPasteboard.general.string = output }
                        .font(.caption)
                }) {
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
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                let stage = URL(fileURLWithPath: Engine.shared.stagingDir())
                let dst = stage.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: dst)
                do {
                    try FileManager.default.copyItem(at: url, to: dst)
                    output = "已导入 \(url.lastPathComponent)（\(dst.fileSizeText)）\n写入目标：\(targetPath)"
                    if let p = pairingPath {
                        Engine.shared.writeDir(pairing: p, sourceDir: stage.path, targetDir: targetPath) { output += "\n" + $0 }
                    } else {
                        output += "\n（未配对，跳过写入）"
                    }
                } catch {
                    output = "导入失败：\(error.localizedDescription)"
                }
            case .failure(let e):
                output = "选择文件失败：\(e.localizedDescription)"
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

    private func doScanSubcaches() {
        let dir = "/System/Cryptexes/OS/System/Library/Caches/com.apple.dyld"
        var names = ["dyld_shared_cache_arm64e"]
        for i in 1...77 { names.append(String(format: "dyld_shared_cache_arm64e.%02d", i)) }
        names.append("dyld_shared_cache_arm64e.25.dylddata")
        names.append("dyld_shared_cache_arm64e.26.dyldreadonly")
        names.append("dyld_shared_cache_arm64e.54.dylddata")
        names.append("dyld_shared_cache_arm64e.55.dyldreadonly")
        names.append("dyld_shared_cache_arm64e.75.dylddata")
        names.append("dyld_shared_cache_arm64e.76.dyldreadonly")
        names.append("dyld_shared_cache_arm64e.77.dyldlinkedit")

        var lines: [String] = []
        for n in names {
            let path = dir + "/" + n
            guard let fh = FileHandle(forReadingAtPath: path) else { continue }
            let head = fh.readData(ofLength: 0x1000)
            try? fh.close()
            guard head.count >= 32, head.prefix(7) == Data("dyld_v1".utf8) else { continue }
            let mo = head.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }
            let mc = head.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt32.self) }
            var lo = UInt64.max, hi: UInt64 = 0
            for k in 0..<Int(mc) {
                let o = Int(mo) + k * 32
                guard o + 24 <= head.count else { continue }
                let addr = head.withUnsafeBytes { $0.load(fromByteOffset: o, as: UInt64.self) }
                let size = head.withUnsafeBytes { $0.load(fromByteOffset: o + 8, as: UInt64.self) }
                lo = min(lo, addr); hi = max(hi, addr + size)
            }
            lines.append(String(format: "%@  %#llx..%#llx", n, lo, hi))
        }
        output = "子缓存地址范围（\(lines.count) 片）\n\n" + lines.joined(separator: "\n")
        LogBus.shared.append("[scan] subcaches=\(lines.count)")
    }

    private func doChunkRead() {
        let path = readPath
        guard let off = Int64(chunkOffset), let len = Int(chunkSize), len > 0 else {
            output = "偏移/长度格式不对"; return
        }
        guard let fh = FileHandle(forReadingAtPath: path) else {
            output = "打不开：\(path)"; return
        }
        defer { try? fh.close() }
        do {
            try fh.seek(toOffset: UInt64(off))
            let data = fh.readData(ofLength: len)
            guard !data.isEmpty else { output = "读到 0 字节（偏移越界？）"; return }
            let name = (path as NSString).lastPathComponent + ".part\(off)"
            let dest = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(name)
            try data.write(to: dest)
            output = "✅ 分段读取 \(data.count) 字节 @ \(off)\n本地：\(name)"
            LogBus.shared.append("[chunk] \(path) @\(off) -> \(data.count) B")
        } catch {
            output = "分段读取失败：\(error.localizedDescription)"
        }
    }

    private func doListPlain() {
        let p = readPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else {
            output = "路径不存在或不是目录：\(p)"
            return
        }
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: p) else {
            output = "列目录失败（沙盒拒绝）：\(p)"
            return
        }
        let key = listFilter.trimmingCharacters(in: .whitespaces)
        let filtered = key.isEmpty ? items.sorted()
                                   : items.filter { $0.localizedCaseInsensitiveContains(key) }.sorted()
        let sorted = filtered
        let head = sorted.prefix(150).joined(separator: "\n")
        output = "📂 \(p)\n过滤=\(key.isEmpty ? "(全部)" : key) → \(sorted.count) 项\n\n" + head
        LogBus.shared.append("[list] \(p) -> \(sorted.count) 项")
    }

    private func doPull() {
        guard let p = pairingPath else { output = "先配对"; return }
        output = "读取中（搬出 → 读 → 搬回）…"
        Engine.shared.pull(pairing: p, devicePath: readPath) { output = $0 }
    }

    private func doReadPrefs() {
        guard let p = pairingPath else { output = "先配对"; return }
        output = "定位 \(bundleID) 容器…"
        let bid = bundleID
        Engine.shared.container(pairing: p, bundleID: bid) { c in
            guard let c = c else { output = "找不到容器"; return }
            let path = c + "/Library/Preferences/" + bid + ".plist"
            output = "读取 \(path)…"
            Engine.shared.pull(pairing: p, devicePath: path) { output = $0 }
        }
    }

    private func doHA() {
        guard let p = pairingPath else { output = "先配对"; return }
        output = "探测 house_arrest（\(bundleID)）…"
        Engine.shared.haProbe(pairing: p, bundleID: bundleID) { output = $0 }
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


extension URL {
    var fileSizeText: String {
        let n = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(n ?? 0), countStyle: .file)
    }
}
