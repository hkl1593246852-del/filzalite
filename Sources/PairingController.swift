import Foundation
import AirliftFFI

/// 驱动 RPPairing 主机：申请本地网络权限、Bonjour 广播、等用户在设置里确认 PIN。
@MainActor
final class PairingController: ObservableObject {

    static let shared = PairingController()

    private let hostName = "FilzaLite"
    private let hostModel = "Mac17,7"
    private let bindAddress = "0.0.0.0"

    private var netService: NetService?
    private let localNetwork = LocalNetworkAuthorization()
    private let keepAlive = KeepAlive()

    @Published private(set) var running = false
    @Published var pairingStatus: String = "待配对"
    @Published var pairingPIN: String? = nil

    static var customPairingFilePath: String? = nil
    private static let altIRKKey = "filzalitePairingHostAltIRK"
    nonisolated private static var storedAltIRK: String {
        get { UserDefaults.standard.string(forKey: altIRKKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: altIRKKey) }
    }

    private var pairContinuation: CheckedContinuation<String, Error>?

    static func pairingFilePath() -> String {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("filzalite_pairing.plist").path
    }

    func startAndWait() async throws -> String {
        if running {
            softCancel()
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return try await withCheckedThrowingContinuation { cont in
            pairContinuation = cont
            start()
        }
    }

    func softCancel() {
        stopAdvertising()
        keepAlive.stopAll()
        running = false
        pairingPIN = nil
        pairingStatus = "已取消"
        resolve(.failure(CancellationError()))
    }

    private func resolve(_ result: Result<String, Error>) {
        guard let cont = pairContinuation else { return }
        pairContinuation = nil
        cont.resume(with: result)
    }

    func start() {
        stopAdvertising()
        keepAlive.stopAll()
        running = true
        pairingPIN = nil
        pairingStatus = "启动本机配对服务…"

        Task {
            _ = await localNetwork.request()
            guard running else { return }
            keepAlive.startAudio()
            pairingStatus = "广播中：去 设置 › 隐私与安全 › 开发者模式 配对"
            runHost()
        }
    }

    private func runHost() {
        let bind = bindAddress
        let name = hostName
        let model = hostModel
        let outPath = Self.pairingFilePath()
        let altIRK = Self.storedAltIRK
        nonisolated(unsafe) let ctx = UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque())

        DispatchQueue.global(qos: .userInitiated).async {
            var result = ALPairResult()
            let rc = bind.withCString { bindC in
                name.withCString { nameC in
                    model.withCString { modelC in
                        outPath.withCString { outC in
                            altIRK.withCString { irkC in
                                al_pairing_run_host(bindC, 0, nameC, modelC, outC, irkC,
                                                    pairReadyCallback, pairPinCallback, ctx, &result)
                            }
                        }
                    }
                }
            }

            let outcome: Outcome
            if rc == 0 {
                let issued = cStr(result.host_alt_irk_hex)
                if !issued.isEmpty { Self.storedAltIRK = issued }
                let devName = cStr(result.device_name)
                let filePath = cStr(result.pairing_file_path)
                outcome = .success(name: devName.isEmpty ? "iPhone" : devName,
                                   path: filePath.isEmpty ? outPath : filePath)
            } else {
                let msg = cStr(result.error)
                outcome = .failure(msg.isEmpty ? "配对失败 (rc=\(rc))" : msg)
            }
            al_pairing_result_free(&result)

            DispatchQueue.main.async {
                Unmanaged<PairingController>.fromOpaque(ctx).release()
                self.finish(outcome)
            }
        }
    }

    private enum Outcome {
        case success(name: String, path: String)
        case failure(String)
    }

    private func finish(_ outcome: Outcome) {
        stopAdvertising()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.keepAlive.stopAll()
        }
        running = false
        pairingPIN = nil

        switch outcome {
        case let .success(name, path):
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            if size == 0 {
                pairingStatus = "失败：配对文件为空"
                resolve(.failure(NSError(domain: "filzalite", code: 1,
                                         userInfo: [NSLocalizedDescriptionKey: "配对文件为空"])))
            } else {
                Self.customPairingFilePath = path
                pairingStatus = "已配对：\(name)（\(size) B）"
                LogBus.shared.append("[pair] 配对文件: \(path) (\(size) B)")
                resolve(.success(path))
            }
        case let .failure(message):
            pairingStatus = "失败：\(message)"
            resolve(.failure(NSError(domain: "filzalite", code: 2,
                                     userInfo: [NSLocalizedDescriptionKey: message])))
        }
    }

    // MARK: Bonjour

    fileprivate func startAdvertising(serviceID: String, port: Int32, txt: [String: Data]) {
        stopAdvertising()
        let service = NetService(domain: "", type: "_remotepairing-pairable-host._tcp.",
                                 name: serviceID, port: port)
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        netService = service
        pairingStatus = "广播中 — 打开 设置 › 隐私与安全 › 开发者模式"
    }

    fileprivate func presentPin(_ pin: String) {
        pairingPIN = pin
        pairingStatus = "在 设置 › 开发者模式 › 与 FilzaLite 配对 中输入 \(pin)"
    }

    private func stopAdvertising() {
        netService?.stop()
        netService = nil
    }
}

private let pairReadyCallback: ALPairReadyCb = { ctx, serviceID, port, keys, vals, count in
    guard let ctx = ctx, let serviceID = serviceID else { return }
    let controller = Unmanaged<PairingController>.fromOpaque(ctx).takeUnretainedValue()
    let id = String(cString: serviceID)
    var txt: [String: Data] = [:]
    if let keys = keys, let vals = vals {
        for i in 0..<Int(count) {
            guard let k = keys[i], let v = vals[i] else { continue }
            txt[String(cString: k)] = Data(String(cString: v).utf8)
        }
    }
    DispatchQueue.main.async {
        controller.startAdvertising(serviceID: id, port: Int32(port), txt: txt)
    }
}

private let pairPinCallback: ALPairPinCb = { pin, ctx in
    guard let ctx = ctx, let pin = pin else { return }
    let controller = Unmanaged<PairingController>.fromOpaque(ctx).takeUnretainedValue()
    let pinString = String(cString: pin)
    DispatchQueue.main.async { controller.presentPin(pinString) }
}

private func cStr(_ ptr: UnsafeMutablePointer<CChar>?) -> String {
    guard let ptr = ptr else { return "" }
    return String(cString: ptr)
}
