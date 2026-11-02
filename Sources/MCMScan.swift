import Foundation

/// ContainerManager 私有 API 参数空间扫描器（带符号诊断）
final class MCMScan {

    typealias FnCreate = @convention(c) () -> OpaquePointer?
    typealias FnSetU64 = @convention(c) (OpaquePointer?, UInt64) -> Void
    typealias FnSetStr = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Void
    typealias FnSetIDs = @convention(c) (OpaquePointer?, OpaquePointer?) -> Void
    typealias FnSingle = @convention(c) (OpaquePointer?) -> OpaquePointer?
    typealias FnGetPath = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?

    private static func find<T>(_ h: UnsafeMutableRawPointer?, _ names: [String], _ t: T.Type) -> (String, T)? {
        for n in names {
            if let p = dlsym(h, n) {
                return (n, unsafeBitCast(p, to: T.self))
            }
        }
        return nil
    }

    private static let flags: [UInt64] = [
        0, UInt64(0x900000000), UInt64(0x8100000000),
        (UInt64(1) << 39) | (UInt64(1) << 32), UInt64(1) << 32, UInt64(1) << 39,
    ]

    static func run(targetBundle: String, log: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // 先试显式路径，失败退回已加载镜像
            var h = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW)
            if h == nil { h = dlopen("libsystem_containermanager.dylib", RTLD_NOW) }
            if h == nil { h = dlopen(nil, RTLD_NOW) }
            guard let handle = h else {
                log("❌ dlopen 失败: \(String(cString: dlerror()))")
                return
            }
            log("✅ dlopen 成功")

            let create: FnCreate? = find(handle, ["container_query_create"], FnCreate.self)?.1
            log("container_query_create: \(create == nil ? "❌" : "✅")")

            let setClass: FnSetU64? = find(handle, ["container_query_set_class"], FnSetU64.self)?.1
            log("container_query_set_class: \(setClass == nil ? "❌" : "✅")")

            let setFlags: FnSetU64? = find(handle, ["container_query_set_flags"], FnSetU64.self)?.1
            log("container_query_set_flags: \(setFlags == nil ? "❌" : "✅")")

            let setPart: FnSetU64? = find(handle, ["container_query_set_part"], FnSetU64.self)?.1
            log("container_query_set_part: \(setPart == nil ? "❌" : "✅")")

            let setIDs: FnSetIDs? = find(handle, ["container_query_set_identifiers"], FnSetIDs.self)?.1
            log("container_query_set_identifiers: \(setIDs == nil ? "❌" : "✅")")

            let singleHit = find(handle, ["container_query_get_single_result",
                                          "container_query_get_result",
                                          "container_query_get_single_object"], FnSingle.self)
            log("get_single_result: \(singleHit == nil ? "❌" : "✅ (\(singleHit!.0))")")

            let pathHit = find(handle, ["container_object_get_path",
                                        "container_object_get_absolute_path",
                                        "container_object_get_url"], FnGetPath.self)
            log("object_get_path: \(pathHit == nil ? "❌" : "✅ (\(pathHit!.0))")")

            guard let create = create, let setClass = setClass, let setFlags = setFlags,
                  let setPart = setPart, let setIDs = setIDs,
                  let single = singleHit?.1, let getPath = pathHit?.1 else {
                log("⛔️ 符号不全，扫描中止（把上面几行发我）")
                return
            }

            log("开始扫描 target=\(targetBundle)")
            var hits = 0, tried = 0
            for cls in UInt64(0)...20 {
                for part in UInt64(0)...3 {
                    for f in flags {
                        tried += 1
                        guard let q = create() else { continue }
                        setClass(q, cls)
                        setFlags(q, f)
                        setPart(q, part)
                        let xp = targetBundle.withCString { xpc_string_create($0) }
                        setIDs(q, OpaquePointer(Unmanaged.passUnretained(xp as AnyObject).toOpaque()))
                        guard let obj = single(q), let cp = getPath(obj) else { continue }
                        let p = String(cString: cp)
                        if p.isEmpty || p.contains("MobileHouseArrest") { continue }
                        hits += 1
                        log("hit class=\(cls) part=\(part) flags=\(String(f, radix: 16)) \(p)")
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: p + "/Documents", isDirectory: &isDir) {
                            log("   ✅ 可访问")
                        }
                    }
                }
            }
            log("扫描完成：\(tried) 组，\(hits) 命中")
        }
    }
}
