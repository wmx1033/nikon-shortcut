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
func check(_ name: String, _ condition: Bool) {
    if condition { print("ok  \(name)") }
    else { failed += 1; print("FAIL \(name)") }
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
elif [[ "$mode" == "read" ]]; then
  swift "$out" "$2"
else
  swift "$out"
fi
rm -f "$out"
