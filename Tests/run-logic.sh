#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/尼康相框水印-脚本.sh"
mode="${1:-test}"
out="$(mktemp /tmp/nikon-logic.XXXXXX.swift)"
python3 - "$src" "$out" "$mode" <<'PY'
import pathlib, sys
src, dest, mode = sys.argv[1:]
text = pathlib.Path(src).read_text(encoding="utf-8")
start = text.index("let watermarkMarker")
end = text.index("func renderedColor")
pure = text[start:end]
if pure.count("{") != pure.count("}"):
    raise SystemExit("纯逻辑花括号不配对")
if mode == "test":
    tail = r'''
func isNikon(make: String, model: String) -> Bool {
    let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    let maker = make.uppercased()
    return maker.contains("NIKON") || model.uppercased().hasPrefix("NIKON")
}
func exifData(_ code: String, _ payload: Data) -> Data {
    var header = Data(code.utf8)
    while header.count < 8 { header.append(0) }
    return header + payload
}
func unicodePayload(_ text: String, _ order: String.Encoding) -> Data {
    var data = Data("UNICODE".utf8)
    data.append(0)
    data.append(contentsOf: text.data(using: order) ?? Data())
    return data
}
var failed = 0
func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition { print("ok  \(name)") }
    else { failed += 1; print("FAIL \(name) \(detail)") }
}
check("marker is WATERMARK", watermarkMarker == "WATERMARK")
check("skip output", isWatermarkFileName("IMG_001-相框"))
check("skip numbered", isWatermarkFileName("IMG_001-相框-2"))
check("keep infix", !isWatermarkFileName("旅行-相框素材"))
for sample in ["DO NOT WATERMARK", "NO WATERMARK"] {
    check("process \(sample)", !containsWatermarkMarker(sample))
    let written = userCommentWithMarker(sample) as? String ?? ""
    check("keep \(sample)", written == sample + "\n" + watermarkMarker)
    check("once \(sample)", userCommentWithMarker(written) as? String == written)
    let markers = written.components(separatedBy: "\n").filter { line in
        let token = line.trimmingCharacters(in: .whitespaces)
        return token == "WATERMARK" || token == "NIKON-WATERMARK"
    }
    check("single \(sample)", markers.count == 1)
}
check("skip standalone", containsWatermarkMarker("说明\nWATERMARK"))
check("skip old line", containsWatermarkMarker("NIKON-WATERMARK"))
check("skip old among text", containsWatermarkMarker("备注\nNIKON-WATERMARK\n"))
check("not watermarked word", !containsWatermarkMarker("WATERMARKED"))
check("prefixed marker", containsWatermarkMarker("ASCII\u{0}\u{0}\u{0}WATERMARK"))
let sunset = userCommentWithMarker("sunset") as? String ?? ""
check("ascii append", sunset == "sunset\nWATERMARK")
check("ascii once", userCommentWithMarker(sunset) as? String == sunset)
check("cjk prepend", userCommentWithMarker("夜景") as? String == "WATERMARK\n夜景")
check("cjk once", userCommentWithMarker(userCommentWithMarker("夜景")) as? String == "WATERMARK\n夜景")
func waterRoundTrip(_ name: String, _ bytes: Data, _ order: String.Encoding) {
    let wrapped = exifData("UNICODE", bytes)
    check("\(name) decode", exifCommentText(wrapped, byteOrder: order) == "水")
    let written = userCommentWithMarker(wrapped, byteOrder: order) as? String ?? ""
    check("\(name) contains", written.contains("水"))
    check("\(name) reread", exifCommentText(unicodePayload(written, order), byteOrder: order)?.contains("水") == true)
}
waterRoundTrip("be", Data([0x6C, 0x34]), .utf16BigEndian)
waterRoundTrip("le", Data([0x34, 0x6C]), .utf16LittleEndian)
let unknown = exifData("UNICODE", Data([0x6C, 0x34]))
check("unknown not decoded", exifCommentText(unknown) == nil)
check("unknown bytes kept", userCommentWithMarker(unknown) as? Data == unknown)
check("bom still decodes", exifCommentText(exifData("UNICODE", Data("东京".data(using: .utf16)!))) == "东京")
check("le needs order", exifCommentText(exifData("UNICODE", Data("东京".data(using: .utf16LittleEndian)!))) == nil)
let jis = exifData("JIS", Data([0x1B, 0x24, 0x42, 0x46, 0x7C, 0x4B, 0x5C, 0x1B, 0x28, 0x42]))
let jisText = exifCommentText(jis)
check("jis decodes", jisText == "日本")
check("jis no escape", jisText?.contains("\u{1B}") != true)
let jisWritten = userCommentWithMarker(jis) as? String ?? ""
check("jis marker", jisWritten.contains("日本") && commentHasWatermarkMarker(jisWritten) && !jisWritten.contains("\u{1B}"))
let jisFile = jpegByReplacingUserComment(Data([0xFF, 0xD8, 0xFF, 0xD9]), jis)!
let jisStored = jpegByReplacingUserComment(jisFile, unicodeCommentBytes(jisWritten))!
let jisReread = exifCommentText(jpegUserComment(jisStored)) ?? ""
check("jis file reread", jisReread.contains("日本") && !jisReread.contains("\u{1B}") && commentHasWatermarkMarker(jisReread))
let badJIS = exifData("JIS", Data([0x1B, 0x24, 0x42, 0x01, 0x02]))
check("bad jis undecoded", exifCommentText(badJIS) == nil)
check("bad jis kept", userCommentWithMarker(badJIS) as? Data == badJIS)
let blob = Data([0xFF, 0xFE, 0x00, 0x01, 0x80, 0x81, 0x82, 0x83, 0xC0, 0xC1])
check("binary preserved", userCommentWithMarker(blob) as? Data == blob)
check("binary needs xmp", commentNeedsSeparateMarker(blob))
let binaryFile = jpegByAddingXMPMarker(jpegByReplacingUserComment(Data([0xFF, 0xD8, 0xFF, 0xD9]), blob)!)!
check("binary file bytes", jpegUserComment(binaryFile) == blob)
check("binary file xmp", jpegHasXMPMarker(binaryFile))
func swapASCII(_ data: Data, _ from: String, _ to: String) -> Data {
    let source = [UInt8](from.utf8)
    let target = [UInt8](to.utf8)
    var bytes = [UInt8](data)
    var cursor = 0
    while cursor + source.count <= bytes.count {
        if Array(bytes[cursor..<(cursor + source.count)]) == source {
            for offset in 0..<target.count { bytes[cursor + offset] = target[offset] }
            cursor += source.count
        } else {
            cursor += 1
        }
    }
    return Data(bytes)
}
let rewrittenPrefix = swapASCII(swapASCII(binaryFile, "xmlns:watermark=", "xmlns:nsprefix1="), "watermark:Marker", "nsprefix1:Marker")
check("rewritten prefix still matches", jpegHasXMPMarker(rewrittenPrefix))
func xmpJPEG(_ inner: String) -> Data {
    let xml = "<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?><x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">" + inner + "</rdf:RDF></x:xmpmeta><?xpacket end=\"w\"?>"
    var payload = Data("http://ns.adobe.com/xap/1.0/\0".utf8)
    payload.append(contentsOf: Data(xml.utf8))
    return insertJPEGSegment(Data([0xFF, 0xD8, 0xFF, 0xD9]), payload: payload)!
}
check("alt prefix attribute", jpegHasXMPMarker(xmpJPEG("<rdf:Description ns1:Marker=\"WATERMARK\" xmlns:ns1=\"http://ns.nikon-shortcut/watermark/1.0/\"/>")))
check("alt prefix element", jpegHasXMPMarker(xmpJPEG("<ns1:Marker xmlns:ns1=\"http://ns.nikon-shortcut/watermark/1.0/\">WATERMARK</ns1:Marker>")))
check("unicode prefix element", jpegHasXMPMarker(xmpJPEG("<rdf:Description xmlns:标记=\"http://ns.nikon-shortcut/watermark/1.0/\"><标记:Marker>WATERMARK</标记:Marker></rdf:Description>")))
func resizedPrefix(_ data: Data, _ prefix: String) -> Data {
    let bytes = [UInt8](data)
    let signature = [UInt8]("http://ns.adobe.com/xap/1.0/\0".utf8)
    var start = 0
    var found = false
    while start + signature.count <= bytes.count {
        if Array(bytes[start..<(start + signature.count)]) == signature { found = true; break }
        start += 1
    }
    guard found, start >= 4, bytes[start - 4] == 0xFF, bytes[start - 3] == 0xE1 else { return data }
    let segmentLength = (Int(bytes[start - 2]) << 8) | Int(bytes[start - 1])
    let payloadEnd = start - 2 + segmentLength
    guard segmentLength >= 2, payloadEnd <= bytes.count else { return data }
    func replace(_ data: Data, _ from: String, _ to: String) -> Data {
        let source = [UInt8](from.utf8)
        let target = [UInt8](to.utf8)
        let input = [UInt8](data)
        var output: [UInt8] = []
        var cursor = 0
        while cursor < input.count {
            if cursor + source.count <= input.count, Array(input[cursor..<(cursor + source.count)]) == source {
                output.append(contentsOf: target)
                cursor += source.count
            } else {
                output.append(input[cursor])
                cursor += 1
            }
        }
        return Data(output)
    }
    var payload = replace(Data(bytes[start..<payloadEnd]), "xmlns:watermark", "xmlns:\(prefix)")
    payload = replace(payload, "watermark:Marker", "\(prefix):Marker")
    let newLength = payload.count + 2
    var output = Data(bytes[..<(start - 2)])
    output.append(UInt8((newLength >> 8) & 0xFF))
    output.append(UInt8(newLength & 0xFF))
    output.append(payload)
    output.append(contentsOf: bytes[payloadEnd...])
    return output
}
let resized = resizedPrefix(binaryFile, "标记")
check("resized unicode prefix matches", jpegHasXMPMarker(resized) && jpegUserComment(resized) == blob)
check("ancestor prefix", jpegHasXMPMarker(xmpJPEG("<rdf:Description xmlns:ns1=\"http://ns.nikon-shortcut/watermark/1.0/\"><rdf:Description ns1:Marker=\"WATERMARK\"/></rdf:Description>")))
check("other namespace ignored", !jpegHasXMPMarker(xmpJPEG("<rdf:Description xmlns:watermark=\"http://example.com/other/\"><watermark:Marker>WATERMARK</watermark:Marker></rdf:Description>")))
check("shadowed namespace ignored", !jpegHasXMPMarker(xmpJPEG("<rdf:Description xmlns:watermark=\"http://ns.nikon-shortcut/watermark/1.0/\"><rdf:Description xmlns:watermark=\"http://example.com/other/\" watermark:Marker=\"WATERMARK\"/></rdf:Description>")))
check("other value ignored", !jpegHasXMPMarker(xmpJPEG("<rdf:Description xmlns:ns1=\"http://ns.nikon-shortcut/watermark/1.0/\" ns1:Marker=\"OTHER\"/>")))
check("other local name ignored", !jpegHasXMPMarker(xmpJPEG("<rdf:Description xmlns:ns1=\"http://ns.nikon-shortcut/watermark/1.0/\" ns1:Note=\"WATERMARK\"/>")))
let zeroHeader = Data(repeating: 0, count: 8) + Data([0x01, 0x00, 0x02, 0xFF, 0x00])
check("zero header undecoded", exifCommentText(zeroHeader) == nil)
check("zero header bytes", userCommentWithMarker(zeroHeader) as? Data == zeroHeader)
check("zero header xmp", commentNeedsSeparateMarker(zeroHeader))
let zeroFile = jpegByAddingXMPMarker(jpegByReplacingUserComment(Data([0xFF, 0xD8, 0xFF, 0xD9]), zeroHeader)!)!
check("zero file bytes", jpegUserComment(zeroFile) == zeroHeader)
check("zero file xmp", jpegHasXMPMarker(zeroFile))
let filler = Data(repeating: 0x11, count: 60000)
let wide = jpegByReplacingUserComment(Data([0xFF, 0xD8, 0xFF, 0xD9]), filler)!
check("wide fits", jpegUserComment(wide) == filler)
let wider = filler + Data([0x22])
check("wide refuses growth", jpegByReplacingUserComment(wide, wider) == nil)
check("commit refuses partial", committedJPEG(wide, restoreComment: wider, stampXMP: false) == nil)
let kept = committedJPEG(Data([0xFF, 0xD8, 0xFF, 0xD9]), restoreComment: Data("ASCII\0\0\0Hi".utf8), stampXMP: false)
check("commit writes comment", jpegUserComment(kept!) == Data("ASCII\0\0\0Hi".utf8))

struct IFD {
    var offset: Int
    var tags: [UInt16]
    var entries: [UInt16: Data]
    var next: Int
}
func tiffLE(_ data: Data) -> Bool { data.count >= 2 && data[0] == 0x49 }
func num16(_ data: Data, _ offset: Int, _ le: Bool) -> UInt16 {
    let low = UInt16(data[offset]), high = UInt16(data[offset + 1])
    return le ? low | (high << 8) : (low << 8) | high
}
func num32(_ data: Data, _ offset: Int, _ le: Bool) -> UInt32 {
    var value: UInt32 = 0
    for index in 0..<4 {
        let byte = UInt32(data[offset + index])
        value |= le ? byte << (8 * index) : byte << (8 * (3 - index))
    }
    return value
}
func readIFD(_ tiff: Data, _ offset: Int) -> IFD? {
    guard tiff.count >= 8, offset + 2 <= tiff.count else { return nil }
    let le = tiffLE(tiff)
    let count = Int(num16(tiff, offset, le))
    let end = offset + 2 + count * 12 + 4
    guard count < 10000, end <= tiff.count else { return nil }
    var tags: [UInt16] = []
    var entries: [UInt16: Data] = [:]
    for index in 0..<count {
        let at = offset + 2 + index * 12
        let entry = Data(tiff[at..<(at + 12)])
        let tag = num16(entry, 0, le)
        tags.append(tag)
        entries[tag] = entry
    }
    return IFD(offset: offset, tags: tags, entries: entries, next: Int(num32(tiff, end - 4, le)))
}
func field32(_ entry: Data, _ tiff: Data) -> Int { Int(num32(entry, 8, tiffLE(tiff))) }
func commentRecord(_ tiff: Data, _ dir: IFD) -> (offset: Int, bytes: Data)? {
    guard let entry = dir.entries[0x9286] else { return nil }
    let count = Int(num32(entry, 4, tiffLE(tiff)))
    let offset = field32(entry, tiff)
    guard count > 4, offset + count <= tiff.count else { return nil }
    return (offset, Data(tiff[offset..<(offset + count)]))
}
func rootIFD(_ tiff: Data) -> IFD? { readIFD(tiff, Int(num32(tiff, 4, tiffLE(tiff)))) }
func exifIFD(_ tiff: Data, _ ifd0: IFD) -> IFD? {
    guard let entry = ifd0.entries[0x8769] else { return nil }
    return readIFD(tiff, field32(entry, tiff))
}
func le16(_ value: Int) -> [UInt8] { [UInt8(value & 255), UInt8((value >> 8) & 255)] }
func le32(_ value: Int) -> [UInt8] { [UInt8(value & 255), UInt8((value >> 8) & 255), UInt8((value >> 16) & 255), UInt8((value >> 24) & 255)] }
func be16(_ value: Int) -> [UInt8] { [UInt8((value >> 8) & 255), UInt8(value & 255)] }
func be32(_ value: Int) -> [UInt8] { [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)] }
func ifdEntry(_ tag: Int, _ type: Int, _ count: Int, _ value: Int, _ big: Bool = false) -> [UInt8] {
    big ? be16(tag) + be16(type) + be32(count) + be32(value) : le16(tag) + le16(type) + le32(count) + le32(value)
}
func jpegWithTIFF(_ tiff: Data) -> Data? {
    guard let base = Data(base64Encoded: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDABALDA4MChAODQ4SERATGCgaGBYWGDEjJR0oOjM9PDkzODdASFxOQERXRTc4UG1RV19iZ2hnPk1xeXBkeFxlZ2P/2wBDARESEhgVGC8aGi9jQjhCY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2P/wAARCAAIAAgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD0CiiigD//2Q==") else { return nil }
    var payload = Data("Exif\0\0".utf8)
    payload.append(tiff)
    return insertJPEGSegment(base, payload: payload)
}
func exiftoolReport(_ jpeg: Data) -> String {
    let url = URL(fileURLWithPath: NSTemporaryDirectory() + "nikon-ifd-\(UUID().uuidString).jpg")
    do { try jpeg.write(to: url) } catch { return "write failed" }
    defer { try? FileManager.default.removeItem(at: url) }
    let output = Pipe()
    let errors = Pipe()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = ["exiftool", "-validate", "-warning", "-error", "-a", "-G1", "-s", "-ExifImageWidth", "-ExifImageHeight", "-GPSLatitude", "-GPSLongitude", url.path]
    proc.standardOutput = output
    proc.standardError = errors
    do { try proc.run() } catch { return "exiftool missing" }
    proc.waitUntilExit()
    let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let error = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return text + error
}
func layoutProblems(_ report: String) -> String {
    let needles = ["odd offset", "out of order", "out of sequence", "bad offset", "invalid offset"]
    return report.split(separator: "\n").map(String.init).filter { line in
        let lower = line.lowercased()
        return needles.contains { lower.contains($0) }
    }.joined(separator: " | ")
}
func even(_ value: Int) -> Bool { value % 2 == 0 }

var dimensions = Data(le16(0x4949) + le16(42) + le32(8))
dimensions.append(contentsOf: le16(1) + ifdEntry(0x8769, 4, 1, 26) + le32(0))
dimensions.append(contentsOf: le16(3))
dimensions.append(contentsOf: ifdEntry(0xA003, 4, 1, 400))
dimensions.append(contentsOf: ifdEntry(0xA002, 4, 1, 640))
dimensions.append(contentsOf: ifdEntry(0x9286, 7, blob.count, 68))
dimensions.append(contentsOf: le32(0))
dimensions.append(blob)
let dimensionJPEG = jpegWithTIFF(dimensions)!
let dimensionOut = jpegByReplacingUserComment(dimensionJPEG, blob)!
let dimensionTIFF = exifTIFF(dimensionOut)!
let dimensionRoot = rootIFD(dimensionTIFF)!
let dimensionExif = exifIFD(dimensionTIFF, dimensionRoot)!
let dimensionComment = commentRecord(dimensionTIFF, dimensionExif)!
check("9286 once and before dimensions", dimensionExif.tags == [0x9286, 0xA002, 0xA003])
check("dimension entries preserved", dimensionExif.entries[0xA002] == Data(ifdEntry(0xA002, 4, 1, 640)) && dimensionExif.entries[0xA003] == Data(ifdEntry(0xA003, 4, 1, 400)))
check("dimension comment bytes", dimensionComment.bytes == blob && dimensionComment.offset % 2 == 0)
check("dimension directories even", even(dimensionRoot.offset) && even(dimensionExif.offset) && field32(dimensionRoot.entries[0x8769]!, dimensionTIFF) == dimensionExif.offset)
check("dimension next preserved", dimensionExif.next == 0)
let dimensionReport = exiftoolReport(dimensionOut)
check("exiftool reads dimensions", dimensionReport.contains("ExifImageWidth") && dimensionReport.contains("640") && dimensionReport.contains("ExifImageHeight") && dimensionReport.contains("400"), dimensionReport)
check("dimension layout warnings", layoutProblems(dimensionReport).isEmpty, dimensionReport)

var added = Data(le16(0x4949) + le16(42) + le32(8))
added.append(contentsOf: le16(1) + ifdEntry(0x8769, 4, 1, 26) + le32(0))
added.append(contentsOf: le16(2) + ifdEntry(0xA003, 4, 1, 400) + ifdEntry(0xA002, 4, 1, 640) + le32(0))
let addedOut = jpegByReplacingUserComment(jpegWithTIFF(added)!, blob)!
let addedExif = exifIFD(exifTIFF(addedOut)!, rootIFD(exifTIFF(addedOut)!)!)!
check("added comment sorts before dimensions", addedExif.tags == [0x9286, 0xA002, 0xA003] && commentRecord(exifTIFF(addedOut)!, addedExif)?.bytes == blob)

var gps = Data(le16(0x4949) + le16(42) + le32(8))
gps.append(contentsOf: le16(1) + ifdEntry(0x8825, 4, 1, 26) + le32(0))
gps.append(contentsOf: le16(4))
gps.append(contentsOf: ifdEntry(0x0001, 2, 2, 0x4E))
gps.append(contentsOf: ifdEntry(0x0002, 5, 3, 80))
gps.append(contentsOf: ifdEntry(0x0003, 2, 2, 0x45))
gps.append(contentsOf: ifdEntry(0x0004, 5, 3, 104))
gps.append(contentsOf: le32(0))
gps.append(contentsOf: le32(30) + le32(1) + le32(0) + le32(1) + le32(0) + le32(1))
gps.append(contentsOf: le32(120) + le32(1) + le32(0) + le32(1) + le32(0) + le32(1))
gps.append(0xAB)
let gpsJPEG = jpegWithTIFF(gps)!
let gpsSeen = exifTIFF(gpsJPEG)!
let gpsSeenRoot = rootIFD(gpsSeen)!
check("writer input has gps", gpsSeenRoot.tags == [0x8825] && field32(gpsSeenRoot.entries[0x8825]!, gpsSeen) == 26)
check("writer input has no exif", gpsSeenRoot.entries[0x8769] == nil)
let gpsOut = jpegByReplacingUserComment(gpsJPEG, zeroHeader)!
let gpsTIFF = exifTIFF(gpsOut)!
let gpsRoot = rootIFD(gpsTIFF)!
let gpsExif = exifIFD(gpsTIFF, gpsRoot)!
let gpsComment = commentRecord(gpsTIFF, gpsExif)!
check("8769 before 8825", gpsRoot.tags == [0x8769, 0x8825])
check("gps entry preserved", gpsRoot.entries[0x8825] == Data(ifdEntry(0x8825, 4, 1, 26)) && gpsRoot.next == 0)
check("new directories even", even(gpsRoot.offset) && even(gpsExif.offset) && even(gpsComment.offset))
check("pointers land on directories", field32(gpsRoot.entries[0x8769]!, gpsTIFF) == gpsExif.offset && field32(gpsRoot.entries[0x8825]!, gpsTIFF) == 26)
check("odd comment stays 13 bytes", gpsComment.bytes == zeroHeader && gpsTIFF[gpsComment.offset - 1] == 0 && gpsTIFF.contains(0xAB))
check("gps directory kept", readIFD(gpsTIFF, 26)?.tags == [0x0001, 0x0002, 0x0003, 0x0004])
let gpsReport = exiftoolReport(gpsOut)
check("exiftool reads gps", gpsReport.contains("GPSLatitude") && gpsReport.contains("30") && gpsReport.contains("GPSLongitude") && gpsReport.contains("120"), gpsReport)
check("gps layout warnings", layoutProblems(gpsReport).isEmpty, gpsReport)
func reportLines(_ report: String) -> String {
    report.split(separator: "\n").map(String.init).filter { line in
        ["Validate", "Warning", "Error", "ExifImageWidth", "ExifImageHeight", "GPSLatitude", "GPSLongitude"].contains { line.contains($0) }
    }.joined(separator: "\n")
}
print("dimension exif \(dimensionExif.tags.map { String(format: "%04X", $0) }.joined(separator: ",")) comment \(dimensionComment.offset) \(dimensionComment.bytes.count)")
print(reportLines(dimensionReport))
print("gps ifd0 \(gpsRoot.tags.map { String(format: "%04X", $0) }.joined(separator: ",")) exif \(gpsExif.offset) comment \(gpsComment.offset) \(gpsComment.bytes.count)")
print(reportLines(gpsReport))

var big = Data(be16(0x4D4D) + be16(42) + be32(8))
big.append(contentsOf: be16(1) + ifdEntry(0x8825, 4, 1, 26, true) + be32(0))
big.append(contentsOf: be16(1) + ifdEntry(0x0001, 2, 2, 0x4E000000, true) + be32(0))
big.append(0xAB)
let bigOut = jpegByReplacingUserComment(jpegWithTIFF(big)!, zeroHeader)!
let bigTIFF = exifTIFF(bigOut)!
let bigRoot = rootIFD(bigTIFF)!
let bigExif = exifIFD(bigTIFF, bigRoot)!
let bigComment = commentRecord(bigTIFF, bigExif)!
check("be 8769 before 8825", bigRoot.tags == [0x8769, 0x8825] && bigRoot.entries[0x8825] == Data(ifdEntry(0x8825, 4, 1, 26, true)))
check("be offsets even and comment unchanged", even(bigRoot.offset) && even(bigExif.offset) && even(bigComment.offset) && bigComment.bytes == zeroHeader && field32(bigRoot.entries[0x8769]!, bigTIFF) == bigExif.offset)

check("nil space converts", colorSpaceNeedsSRGB(nil))
check("display p3 kept", !colorSpaceNeedsSRGB("kCGColorSpaceDisplayP3"))
check("adobe converts", colorSpaceNeedsSRGB("kCGColorSpaceAdobeRGB1998"))
check("missing body", !isNikon(make: "", model: ""))
check("sony missing model", !isNikon(make: "SONY", model: ""))
check("nikon make", isNikon(make: "NIKON CORPORATION", model: ""))
check("canon", !isNikon(make: "Canon", model: "EOS R5"))
if failed != 0 {
    print("\(failed) failed")
    exit(1)
}
print("logic passed")
'''
elif mode == "order":
    tail = r'''
struct IFD {
    var offset: Int
    var tags: [UInt16]
    var entries: [UInt16: Data]
    var next: Int
}
func tiffLE(_ data: Data) -> Bool { data.count >= 2 && data[0] == 0x49 }
func num16(_ data: Data, _ offset: Int, _ le: Bool) -> UInt16 {
    let low = UInt16(data[offset]), high = UInt16(data[offset + 1])
    return le ? low | (high << 8) : (low << 8) | high
}
func num32(_ data: Data, _ offset: Int, _ le: Bool) -> UInt32 {
    var value: UInt32 = 0
    for index in 0..<4 {
        let byte = UInt32(data[offset + index])
        value |= le ? byte << (8 * index) : byte << (8 * (3 - index))
    }
    return value
}
func readIFD(_ tiff: Data, _ offset: Int) -> IFD? {
    guard tiff.count >= 8, offset + 2 <= tiff.count else { return nil }
    let le = tiffLE(tiff)
    let count = Int(num16(tiff, offset, le))
    let end = offset + 2 + count * 12 + 4
    guard count < 10000, end <= tiff.count else { return nil }
    var tags: [UInt16] = []
    var entries: [UInt16: Data] = [:]
    for index in 0..<count {
        let at = offset + 2 + index * 12
        let entry = Data(tiff[at..<(at + 12)])
        let tag = num16(entry, 0, le)
        tags.append(tag)
        entries[tag] = entry
    }
    return IFD(offset: offset, tags: tags, entries: entries, next: Int(num32(tiff, end - 4, le)))
}
func field32(_ entry: Data, _ tiff: Data) -> Int { Int(num32(entry, 8, tiffLE(tiff))) }
func commentRecord(_ tiff: Data, _ dir: IFD) -> (offset: Int, bytes: Data)? {
    guard let entry = dir.entries[0x9286] else { return nil }
    let count = Int(num32(entry, 4, tiffLE(tiff)))
    let offset = field32(entry, tiff)
    guard count > 4, offset + count <= tiff.count else { return nil }
    return (offset, Data(tiff[offset..<(offset + count)]))
}
let path = CommandLine.arguments[1]
let jpeg = try Data(contentsOf: URL(fileURLWithPath: path))
guard let tiff = exifTIFF(jpeg) else { print("NOEXIF"); exit(0) }
let le = tiffLE(tiff)
guard let ifd0 = readIFD(tiff, Int(num32(tiff, 4, le))) else { print("BAD"); exit(1) }
func labels(_ tags: [UInt16]) -> String { tags.map { String(format: "%04X", $0) }.joined(separator: ",") }
print("ifd0 \(ifd0.offset) \(labels(ifd0.tags))")
let home = ifd0.entries[0x8769].flatMap { readIFD(tiff, field32($0, tiff)) }
if let exif = home {
    print("exif \(exif.offset) \(labels(exif.tags))")
    if let record = commentRecord(tiff, exif) {
        print("comment \(record.offset) \(record.bytes.count) \(record.bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
    } else { print("comment none") }
} else {
    print("exif none")
    if let record = commentRecord(tiff, ifd0) {
        print("comment \(record.offset) \(record.bytes.count) \(record.bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
    } else { print("comment none") }
}
if let gps = ifd0.entries[0x8825] { print("gps \(field32(gps, tiff))") } else { print("gps none") }
'''
else:
    tail = r'''
let path = CommandLine.arguments[1]
let jpeg = try Data(contentsOf: URL(fileURLWithPath: path))
if CommandLine.arguments.count == 2 {
    if let comment = jpegUserComment(jpeg) {
        print(comment.map { String(format: "%02X", $0) }.joined(separator: " "))
    } else {
        print("NONE")
    }
    print(jpegHasXMPMarker(jpeg) ? "XMP yes" : "XMP no")
} else {
    let bytes = CommandLine.arguments[2].split(separator: " ").compactMap { UInt8($0, radix: 16) }
    guard let updated = jpegByReplacingUserComment(jpeg, Data(bytes)) else {
        fputs("patch failed\n", stderr)
        exit(1)
    }
    try updated.write(to: URL(fileURLWithPath: path))
}
'''
pathlib.Path(dest).write_text("import Foundation\n" + pure + tail, encoding="utf-8")
PY
if [[ "$mode" == "patch" ]]; then
  swift "$out" "$2" "$3"
elif [[ "$mode" == "read" || "$mode" == "order" ]]; then
  swift "$out" "$2"
else
  swift "$out"
fi
rm -f "$out"
