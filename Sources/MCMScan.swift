import Foundation

/// ContainerManager 参数空间扫描器 —— 全可选调用，不做守卫中止
final class MCMScan {

    typealias FnCreate = @convention(c) () -> OpaquePointer?
    typealias FnSetU64 = @convention(c) (OpaquePointer?, UInt64) -> Void
    typealias FnSetIDs = @convention(c) (OpaquePointer?, OpaquePointer?) -> Void
    typealias FnSingle = @convention(c) (OpaquePointer?) -> OpaquePointer?
    typealias FnGetPath = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?

    private static func bind<T>(_ h: UnsafeMutableRawPointer, _ n: String, _ t: T.Type) -> T? {
        guard let p = dlsym(h, n) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    private static let flags: [UInt64] = [
        0, UInt64(0x900000000), UInt64(0x8100000000),
        (UInt64(1) << 39) | (UInt64(1) << 32), UInt64(1) << 32, UInt64(1) << 39,
    ]

    static func run(targetBundle: String, log: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var h = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW)
            if h == nil { h = dlopen("libsystem_containermanager.dylib", RTLD_NOW) }
            if h == nil { h = dlopen(nil, RTLD_NOW) }
            guard let handle = h else {
                log("❌ dlopen 失败"); return
            }
            log("✅ dlopen 成功 [scanner build v4 · no guard]")

            let create = bind(handle, "container_query_create", FnCreate.self)
            let setClass = bind(handle, "container_query_set_class", FnSetU64.self)
            let setFlags = bind(handle, "container_query_set_flags", FnSetU64.self)
            let setPart = bind(handle, "container_query_set_part", FnSetU64.self)
            let setIDs = bind(handle, "container_query_set_identifiers", FnSetIDs.self)
            let single = bind(handle, "container_query_get_single_result", FnSingle.self)
            let getPath = bind(handle, "container_object_get_path", FnGetPath.self)

            log("create=\(create != nil) class=\(setClass != nil) flags=\(setFlags != nil) part=\(setPart != nil) ids=\(setIDs != nil) single=\(single != nil) path=\(getPath != nil)")

            var tried = 0, hits = 0
            for cls in UInt64(0)...20 {
                for f in flags {
                    tried += 1
                    guard let q = create?() else { continue }
                    setClass?(q, cls)
                    setFlags?(q, f)
                    setPart?(q, 0)
                    let xp = targetBundle.withCString { xpc_string_create($0) }
                    setIDs?(q, OpaquePointer(Unmanaged.passUnretained(xp as AnyObject).toOpaque()))

                    guard let obj = single?(q), let cp = getPath?(obj) else { continue }
                    let p = String(cString: cp)
                    if p.isEmpty || p.contains("MobileHouseArrest") { continue }
                    hits += 1
                    log("hit class=\(cls) flags=\(String(f, radix: 16)) \(p)")
                    if FileManager.default.fileExists(atPath: p + "/Documents") {
                        log("   ✅ 可访问")
                    }
                }
            }
            log("扫描完成：\(tried) 组，\(hits) 命中")
        }
    }
}
