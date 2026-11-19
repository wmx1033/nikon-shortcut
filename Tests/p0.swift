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
func show(_ text: String) -> String {
    text.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\0", with: "\\0")
}

func expect(_ condition: Bool, _ name: String, _ detail: String = "") {
    if condition {
        print("ok  \(name)")
    } else {
        failures.append(name)
        print("FAIL \(name) \(show(detail))")
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
          let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] else { return "" }
    let value = exif[kCGImagePropertyExifUserComment as String]
    if let text = value as? String { return text.replacingOccurrences(of: "\0", with: "") }
    if let data = value as? Data {
        if data.count >= 8 {
            let header = String(data: data.prefix(8), encoding: .ascii) ?? ""
            let payload = Data(data.dropFirst(8))
            if header.hasPrefix("UNICODE"), let text = String(data: payload, encoding: .utf16LittleEndian) ?? String(data: payload, encoding: .utf16) {
                return text.replacingOccurrences(of: "\0", with: "")
            }
        }
        return String(data: data, encoding: .utf8)?.replacingOccurrences(of: "\0", with: "") ?? ""
    }
    return ""
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
let note = try writeJPEG(name: "note.jpg", space: srgb, comment: "sunset")
let doNot = try writeJPEG(name: "do-not.jpg", space: srgb, comment: "DO NOT WATERMARK")
let noMark = try writeJPEG(name: "no-mark.jpg", space: srgb, comment: "NO WATERMARK")
let cjk = try writeJPEG(name: "cjk.jpg", space: srgb)
let jisFile = try writeJPEG(name: "jis.jpg", space: srgb)
let binaryFile = try writeJPEG(name: "binary.jpg", space: srgb)
let logic = root.appendingPathComponent("Tests/run-logic.sh")
func runLogic(_ args: [String]) throws -> String {
    let pipe = Pipe()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/bash")
    proc.arguments = [logic.path] + args
    proc.standardOutput = pipe
    try proc.run()
    proc.waitUntilExit()
    let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if proc.terminationStatus != 0 { throw CocoaError(.fileWriteUnknown) }
    return text
}
let jisBytes: [UInt8] = [0x4A, 0x49, 0x53, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1B, 0x24, 0x42, 0x46, 0x7C, 0x4B, 0x5C, 0x1B, 0x28, 0x42]
let blob: [UInt8] = [0xFF, 0xFE, 0x00, 0x01, 0x80, 0x81, 0x82, 0x83, 0xC0, 0xC1]
func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
var cjkBytes = Data("UNICODE".utf8)
cjkBytes.append(0)
cjkBytes.append(contentsOf: "夜景".data(using: .utf16) ?? Data())
try runLogic(["patch", cjk.path, hex([UInt8](cjkBytes))])
try runLogic(["patch", jisFile.path, hex(jisBytes)])
try runLogic(["patch", binaryFile.path, hex(blob)])
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
proc.arguments = [script.path, plain.path, sony.path, nikonMake.path, nikonModel.path, canon.path, infix.path, framed.path, framedNumber.path, note.path, doNot.path, noMark.path, cjk.path, jisFile.path, binaryFile.path, oldMarker.path, newMarker.path, adobeFile.path, p3File.path]
proc.standardError = errorPipe
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
expect(produced(doNot), "DO NOT WATERMARK 会输出")
expect(produced(noMark), "NO WATERMARK 会输出")
expect(produced(cjk), "带中文注释的照片会输出")
expect(produced(jisFile), "JIS 注释会输出")
expect(produced(binaryFile), "无法解码的注释会输出")
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
expect(noteComment == "sunset\nWATERMARK", "英文注释保留并追加 WATERMARK", noteComment)
expect(comment(of: outputURL(doNot)) == "DO NOT WATERMARK\nWATERMARK", "DO NOT WATERMARK 保留原文并只加一个标记", comment(of: outputURL(doNot)))
expect(comment(of: outputURL(noMark)) == "NO WATERMARK\nWATERMARK", "NO WATERMARK 保留原文并只加一个标记", comment(of: outputURL(noMark)))
func fileComment(_ url: URL) throws -> (hex: String, xmp: Bool) {
    let text = try runLogic(["read", url.path])
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let marker = lines.count > 1 ? lines[1] : ""
    return (lines.first ?? "", marker == "XMP yes")
}
func textFromCommentHex(_ hexText: String) -> String {
    let bytes = hexText.split(separator: " ").compactMap { UInt8($0, radix: 16) }
    let data = Data(bytes)
    guard data.count >= 8 else { return "" }
    let header = String(data: data.prefix(8), encoding: .ascii) ?? ""
    let payload = Data(data.dropFirst(8))
    if header.hasPrefix("UNICODE") { return String(data: payload, encoding: .utf16)?.replacingOccurrences(of: "\0", with: "") ?? "" }
    if header.hasPrefix("JIS") { return String(data: payload, encoding: .iso2022JP) ?? "" }
    return String(data: payload, encoding: .utf8) ?? ""
}
let jisRead = try fileComment(outputURL(jisFile))
let jisText = textFromCommentHex(jisRead.hex)
expect(jisText.contains("日本") && !jisText.contains("\u{1B}") && jisText.contains("WATERMARK"), "JIS 注释写回后仍是日本且标记可读", show(jisText))
let binaryRead = try fileComment(outputURL(binaryFile))
expect(binaryRead.hex == hex(blob), "无法解码的注释逐字节保留", binaryRead.hex)
expect(binaryRead.xmp, "无法解码的注释带有 XMP 标记")
let renamed = work.appendingPathComponent("binary-renamed.jpg")
try FileManager.default.copyItem(at: outputURL(binaryFile), to: renamed)
let before = try Data(contentsOf: renamed)
let secondErr = Pipe()
let second = Process()
second.executableURL = URL(fileURLWithPath: "/bin/bash")
second.arguments = [script.path, renamed.path]
second.standardError = secondErr
try second.run()
second.waitUntilExit()
let secondText = String(data: secondErr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
let after = try Data(contentsOf: renamed)
expect(second.terminationStatus == 0 && secondText.contains("binary-renamed.jpg") && secondText.contains("跳过"), "改名后的二进制成片被跳过", secondText)
expect(before == after && !FileManager.default.fileExists(atPath: outputURL(renamed).path), "跳过时文件没有被改写")
let cjkText = textFromCommentHex((try fileComment(outputURL(cjk))).hex)
expect(cjkText.hasPrefix("WATERMARK") && cjkText.contains("夜景"), "中文注释的标记写在前面并保留夜景", cjkText)
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
