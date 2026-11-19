#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/尼康相框水印-脚本.sh"
out="$(mktemp /tmp/nikon-logic.XXXXXX.swift)"
python3 - "$src" "$out" <<'PY'
import pathlib, sys
src, dest = sys.argv[1:]
text = pathlib.Path(src).read_text(encoding="utf-8")
start = text.index("let watermarkMarker")
end = text.index("func renderedColor")
pure = text[start:end]
if pure.count("{") != pure.count("}"):
    raise SystemExit("纯逻辑花括号不配对")
cases = r'''
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
var failed = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("ok  \(name)") }
    else { failed += 1; print("FAIL \(name)") }
}
check("marker is WATERMARK", watermarkMarker == "WATERMARK")
check("skip output", isWatermarkFileName("IMG_001-相框"))
check("skip numbered", isWatermarkFileName("IMG_001-相框-2"))
check("skip numbered 10", isWatermarkFileName("IMG_001-相框-10"))
check("keep infix", !isWatermarkFileName("旅行-相框素材"))
check("keep trailing hyphen", !isWatermarkFileName("IMG_001-相框-"))
check("keep extra suffix", !isWatermarkFileName("IMG_001-相框-2-extra"))
check("append keeps text", userCommentWithMarker("夜景") as? String == "夜景\nWATERMARK")
let once = userCommentWithMarker("夜景")
check("append once", userCommentWithMarker(once) as? String == once as? String)
check("old marker", containsWatermarkMarker("NIKON-WATERMARK"))
check("plain marker", containsWatermarkMarker("WATERMARK"))
check("prefixed marker", containsWatermarkMarker("ASCII\u{0}\u{0}\u{0}WATERMARK"))
check("prefixed note", exifCommentText("ASCII\u{0}\u{0}\u{0}我的注释") == "我的注释")
let ascii = exifData("ASCII", Data("sunset".utf8))
check("ascii append", userCommentWithMarker(ascii) as? String == "sunset\nWATERMARK")
func roundTrip(_ label: String, _ text: String, _ payload: Data) {
    check(label, exifCommentText(exifData("UNICODE", payload)) == text)
}
roundTrip("utf16le chinese", "东京", Data("东京".data(using: .utf16LittleEndian)!))
roundTrip("utf16be chinese", "东京", Data("东京".data(using: .utf16BigEndian)!))
roundTrip("utf16 bom", "东京", Data("东京".data(using: .utf16)!))
roundTrip("utf16le kana", "しゃしん", Data("しゃしん".data(using: .utf16LittleEndian)!))
let blob = Data([0xFF, 0xFE, 0x00, 0x01, 0x80, 0x81, 0x82, 0x83, 0xC0, 0xC1])
check("binary preserved", userCommentWithMarker(blob) as? Data == blob)
check("nil space converts", colorSpaceNeedsSRGB(nil))
check("display p3 kept", !colorSpaceNeedsSRGB("kCGColorSpaceDisplayP3"))
check("srgb kept", !colorSpaceNeedsSRGB("kCGColorSpaceSRGB"))
check("adobe converts", colorSpaceNeedsSRGB("kCGColorSpaceAdobeRGB1998"))
check("romm converts", colorSpaceNeedsSRGB("kCGColorSpaceROMMRGB"))
check("wide converts", colorSpaceNeedsSRGB("kCGColorSpaceWideGamutRGB"))
check("missing body", !isNikon(make: "", model: ""))
check("sony missing model", !isNikon(make: "SONY", model: ""))
check("nikon make", isNikon(make: "NIKON CORPORATION", model: ""))
check("nikon model", isNikon(make: "", model: "NIKON Z 6II"))
check("canon", !isNikon(make: "Canon", model: "EOS R5"))
if failed != 0 {
    print("\(failed) failed")
    exit(1)
}
print("logic passed")
'''
pathlib.Path(dest).write_text("import Foundation\n" + pure + cases, encoding="utf-8")
PY
swift "$out"
rm -f "$out"
