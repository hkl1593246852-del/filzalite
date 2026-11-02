import Foundation

/// ContainerManager 私有 API 参数空间扫描器
/// 目的：在 27.0.1 上找出是否还有「某个 class/flags/part 组合」会给别的容器发 extension
final class MCMScan {

    typealias FnCreate = @convention(c) () -> OpaquePointer?
    typealias FnSetClass = @convention(c) (OpaquePointer?, UInt64) -> Void
    typealias FnSetFlags = @convention(c) (OpaquePointer?, UInt64) -> Void
    typealias FnSetPart = @convention(c) (OpaquePointer?, UInt64) -> Void
    typealias FnSetPartDomain = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Void
    typealias FnSetIDs = @convention(c) (OpaquePointer?, OpaquePointer?) -> Void
    typealias FnSingle = @convention(c) (OpaquePointer?) -> OpaquePointer?
    typealias FnGetPath = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?

    private static func bind<T>(_ h: UnsafeMutableRawPointer, _ name: String, _ t: T.Type) -> T? {
        guard let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    /// 已知出现过的 flags 候选
    private static let flagCandidates: [UInt64] = [
        0,
        UInt64(0x900000000),
        UInt64(0x8100000000),
        (UInt64(1) << 39) | (UInt64(1) << 32),
        UInt64(1) << 32,
        UInt64(1) << 39,
    ]

    static func run(targetBundle: String, log: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let h = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW) else {
                log("❌ dlopen libsystem_containermanager 失败")
                return
            }
            guard let create = bind(h, "container_query_create", FnCreate.self),
                  let setClass = bind(h, "container_query_set_class", FnSetClass.self),
                  let setFlags = bind(h, "container_query_set_flags", FnSetFlags.self),
                  let setPart = bind(h, "container_query_set_part", FnSetPart.self),
                  let setIDs = bind(h, "container_query_set_identifiers", FnSetIDs.self),
                  let single = bind(h, "container_query_get_single_result", FnSingle.self),
                  let getPath = bind(h, "container_object_get_path", FnGetPath.self)
            else {
                log("❌ 关键符号缺失，说明 API 名变了")
                return
            }
            let setPartDomain = bind(h, "container_query_set_part_domain", FnSetPartDomain.self)

            log("✅ 符号解析完成，开始扫描 target=\(targetBundle)")
            var hits: [String] = []
            var tried = 0

            for cls in UInt64(0)...20 {
                for part in UInt64(0)...3 {
                    for flags in flagCandidates {
                        tried += 1
                        guard let q = create() else { continue }
                        setClass(q, cls)
                        setFlags(q, flags)
                        setPart(q, part)
                        let xp = targetBundle.withCString { xpc_string_create($0) }
                        if let xpRaw = xp {
                            setIDs(q, Unmanaged.passUnretained(xpRaw).toOpaque())
                        }
                        setPartDomain?(q, nil)

                        guard let obj = single(q), let cpath = getPath(obj) else { continue }
                        let path = String(cString: cpath)
                        // 只要不是我们自己的容器，就记一笔
                        if !path.contains("MobileHouseArrest") && !path.isEmpty {
                            let line = "hit class=\(cls) part=\(part) flags=\(String(flags, radix: 16)) path=\(path)"
                            hits.append(line)
                            log(line)
                            // 试开一下，确认是真能读
                            let probe = path + "/Documents"
                            var isDir: ObjCBool = false
                            if FileManager.default.fileExists(atPath: probe, isDirectory: &isDir) {
                                log("   ✅ 可访问：\(probe)")
                            } else {
                                log("   ⚠️ 路径存在但打不开（无 extension）")
                            }
                        }
                    }
                }
            }

            log("扫描完成：\(tried) 组参数，\(hits.count) 个命中")
            if hits.isEmpty {
                log("结论：27.0.1 上这个参数空间已经堵死")
            }
        }
    }
}
