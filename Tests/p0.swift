import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let rootCandidates = [cwd, cwd.deletingLastPathComponent()]
guard let root = rootCandidates.first(where: {
    FileManager.default.fileExists(atPath: $0.appendingPathComponent("尼康相框水印-脚本.sh").path)
}) else {
    fputs("请在仓库根目录运行 swift Tests/p0.swift\n", stderr)
    exit(1)
}
let script = root.appendingPathComponent("尼康相框水印-脚本.sh")
let work = FileManager.default.temporaryDirectory.appendingPathComponent("nikon-p0-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

var failures: [String] = []
func expect(_ condition: Bool, _ name: String, _ detail: String = "") {
    if condition {
        print("ok  \(name)")
    } else {
        failures.append(name)
        print("FAIL \(name) \(detail)")
    }
}

func writeJPEG(name: String, space: CGColorSpace, make: String? = nil, model: String? = nil, comment: String? = nil) throws -> URL {
    let url = work.appendingPathComponent(name)
    guard let ctx = CGContext(
        data: nil, width: 640, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { throw CocoaError(.fileWriteUnknown) }
    let components = [CGFloat](repeating: 1, count: space.numberOfComponents + 1)
    let white = components.withUnsafeBufferPointer { buffer -> CGColor? in
        guard let address = buffer.baseAddress else { return nil }
        return CGColor(colorSpace: space, components: address)
    }
    if let white {
        ctx.setFillColor(white)
    } else {
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    }
    ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    var props: [String: Any] = [kCGImageDestinationLossyCompressionQuality as String: 0.95]
    var tiff: [String: Any] = [:]
    if let make { tiff[kCGImagePropertyTIFFMake as String] = make }
    if let model { tiff[kCGImagePropertyTIFFModel as String] = model }
    if !tiff.isEmpty { props[kCGImagePropertyTIFFDictionary as String] = tiff }
    if let comment {
        props[kCGImagePropertyExifDictionary as String] = [kCGImagePropertyExifUserComment as String: comment]
    }
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    return url
}

func outputURL(_ input: URL) -> URL {
    input.deletingLastPathComponent().appendingPathComponent(input.deletingPathExtension().lastPathComponent + "-相框.jpg")
}

func comment(of url: URL) -> String {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
          let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
          let text = exif[kCGImagePropertyExifUserComment as String] as? String else { return "" }
    return text.replacingOccurrences(of: "\0", with: "")
}

func colorLabel(_ url: URL) -> String {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "unreadable" }
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
    let space = image.colorSpace?.name as String? ?? ""
    let profile = props[kCGImagePropertyProfileName as String] as? String ?? ""
    return "space=\(space) profile=\(profile)"
}

func yellowPixels(_ url: URL) -> Int {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return -1 }
    let width = image.width
    let height = image.height
    let row = width * 4
    var buffer = [UInt8](repeating: 0, count: row * height)
    let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(
            data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: row,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { return -1 }
    var count = 0
    var index = 0
    while index + 3 < buffer.count {
        let red = Int(buffer[index])
        let green = Int(buffer[index + 1])
        let blue = Int(buffer[index + 2])
        if red > 200 && green > 160 && blue < 90 && red > blue + 80 { count += 1 }
        index += 4
    }
    return count
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
guard let adobe = CGColorSpace(name: CGColorSpace.adobeRGB1998),
      let p3 = CGColorSpace(name: CGColorSpace.displayP3) else {
    fputs("系统缺少 Adobe RGB 或 Display P3\n", stderr)
    exit(1)
}

let plain = try writeJPEG(name: "plain.jpg", space: srgb)
let sony = try writeJPEG(name: "sony.jpg", space: srgb, make: "SONY")
let nikonMake = try writeJPEG(name: "nikon-make.jpg", space: srgb, make: "NIKON CORPORATION")
let nikonModel = try writeJPEG(name: "nikon-model.jpg", space: srgb, model: "NIKON Z 8")
let canon = try writeJPEG(name: "canon.jpg", space: srgb, make: "Canon", model: "EOS R5")
let infix = try writeJPEG(name: "旅行-相框素材.jpg", space: srgb)
let framed = try writeJPEG(name: "done-相框.jpg", space: srgb)
let framedNumber = try writeJPEG(name: "done-相框-2.jpg", space: srgb)
let note = try writeJPEG(name: "note.jpg", space: srgb, comment: "夜景")
let oldMarker = try writeJPEG(name: "old.jpg", space: srgb, comment: "NIKON-WATERMARK")
let newMarker = try writeJPEG(name: "marked.jpg", space: srgb, comment: "WATERMARK")
let adobeFile = try writeJPEG(name: "adobe.jpg", space: adobe, make: "NIKON CORPORATION", model: "NIKON Z 8")
let p3File = try writeJPEG(name: "p3.jpg", space: p3, make: "NIKON CORPORATION", model: "NIKON Z 8")

let adobeBefore = colorLabel(adobeFile)
expect(adobeBefore.lowercased().contains("adobe"), "样张确实是 Adobe RGB", adobeBefore)
let p3Before = colorLabel(p3File)
expect(p3Before.lowercased().contains("p3"), "样张确实是 Display P3", p3Before)

let errorPipe = Pipe()
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/bin/bash")
proc.arguments = [script.path, plain.path, sony.path, nikonMake.path, nikonModel.path, canon.path, infix.path, framed.path, framedNumber.path, note.path, oldMarker.path, newMarker.path, adobeFile.path, p3File.path]
proc.standardError = errorPipe
proc.standardOutput = Pipe()
try proc.run()
proc.waitUntilExit()
let errText = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
expect(proc.terminationStatus == 0, "脚本正常结束", "exit \(proc.terminationStatus)\n\(errText)")

func skipped(_ url: URL) -> Bool { !FileManager.default.fileExists(atPath: outputURL(url).path) }
func produced(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: outputURL(url).path) }

expect(produced(plain), "无型号的照片会输出")
expect(produced(sony), "索尼缺型号的照片会输出")
expect(produced(canon), "佳能照片会输出")
expect(produced(infix), "文件名中段含相框的原片会输出")
expect(produced(note), "带普通注释的照片会输出")
expect(produced(nikonMake), "只有 Make 的尼康会输出")
expect(produced(nikonModel), "只有 Model 的尼康会输出")
expect(skipped(framed), "以 -相框 结尾的文件被跳过")
expect(skipped(framedNumber), "以 -相框-数字 结尾的文件被跳过")
expect(skipped(oldMarker), "旧的 NIKON-WATERMARK 被跳过")
expect(skipped(newMarker), "已经带 WATERMARK 的文件被跳过")
expect(errText.contains("done-相框.jpg"), "跳过信息包含文件名")

let plainYellow = yellowPixels(outputURL(plain))
let sonyYellow = yellowPixels(outputURL(sony))
let canonYellow = yellowPixels(outputURL(canon))
let nikonMakeYellow = yellowPixels(outputURL(nikonMake))
let nikonModelYellow = yellowPixels(outputURL(nikonModel))
expect(plainYellow == 0, "缺 Make/Model 不画尼康黄标", "yellow=\(plainYellow)")
expect(sonyYellow == 0, "其他品牌缺 Model 不画尼康黄标", "yellow=\(sonyYellow)")
expect(canonYellow == 0, "佳能不画尼康黄标", "yellow=\(canonYellow)")
expect(nikonMakeYellow > 30, "尼康 Make 会画黄标", "yellow=\(nikonMakeYellow)")
expect(nikonModelYellow > 30, "尼康 Model 会画黄标", "yellow=\(nikonModelYellow)")

let noteComment = comment(of: outputURL(note))
expect(noteComment.contains("夜景") && noteComment.contains("WATERMARK"), "原注释保留并追加 WATERMARK", noteComment)
if let noteRange = noteComment.range(of: "夜景"), let markRange = noteComment.range(of: "WATERMARK") {
    expect(noteRange.lowerBound < markRange.lowerBound, "标记在原注释之后", noteComment)
} else {
    expect(false, "标记在原注释之后", noteComment)
}
expect(comment(of: outputURL(plain)) == "WATERMARK", "没有原注释时只写 WATERMARK", comment(of: outputURL(plain)))

let adobeAfter = colorLabel(outputURL(adobeFile))
expect(adobeAfter.lowercased().contains("srgb") && !adobeAfter.lowercased().contains("adobe"), "Adobe RGB 成片标签是 sRGB", adobeAfter)
let p3After = colorLabel(outputURL(p3File))
expect(p3After.lowercased().contains("p3"), "Display P3 成片仍是 P3", p3After)

if !failures.isEmpty {
    fputs("\(failures.count) 项失败\n\(errText)\n", stderr)
    exit(1)
}
print("script passed")
