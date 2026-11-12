import Foundation
import CryptoKit
guard CommandLine.arguments.count == 4 else { fatalError("usage: fixture workloads.json case output.bin") }
let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: [String: Any]]
let name = CommandLine.arguments[2]
guard let spec = catalog[name] else { fatalError("Unknown fixture") }
let output = URL(fileURLWithPath: CommandLine.arguments[3])
_ = FileManager.default.createFile(atPath: output.path, contents: nil)
let file = try FileHandle(forWritingTo: output)
func write(_ text: String) throws { try file.write(contentsOf: Data(text.utf8)) }
let iterations = spec["iterations"] as! Int
if spec["kind"] as! String == "bmp" {
    let width = spec["width"] as! Int, height = spec["height"] as! Int, color = spec["bgra"] as! [UInt8]
    var bytes = Data(repeating: 0, count: 54+width*height*4)
    bytes[0] = 66; bytes[1] = 77; bytes[26] = 1; bytes[28] = 32
    for (offset, value) in [(2,bytes.count),(10,54),(14,40),(18,width),(22,height),(34,width*height*4)] {
        var little = UInt32(value).littleEndian
        withUnsafeBytes(of: &little) { bytes.replaceSubrange(offset..<offset+4, with: $0) }
    }
    for i in stride(from: 54, to: bytes.count, by: 4) { for c in 0..<4 { bytes[i+c] = color[c] } }
    try file.write(contentsOf: bytes)
} else if spec["kind"] as! String == "rgba" {
    let width = spec["width"] as! Int, height = spec["height"] as! Int
    let payload = Data(Array(repeating: [UInt8(255), 0, 0, 255], count: width*height).flatMap { $0 }).base64EncodedString()
    for image in 0..<iterations {
        let id = spec["replace"] as! Bool ? 1 : image+1
        let bytes = Array(payload.utf8)
        for offset in stride(from: 0, to: bytes.count, by: 4096) {
            let end = min(offset+4096, bytes.count)
            let header = offset == 0 ? "\u{1b}_Ga=T,f=32,s=\(width),v=\(height),i=\(id),q=2,m=" : "\u{1b}_Gm="
            try write(header + (end < bytes.count ? "1" : "0") + ";" + String(decoding: bytes[offset..<end], as: UTF8.self) + "\u{1b}\\")
        }
    }
} else {
    var unit = spec["text"] as? String ?? ""
    if spec["kind"] as! String == "cjk" {
        let start = spec["start"] as! Int, count = spec["count"] as! Int, styles = spec["styles"] as! [String]
        for i in 0..<count {
            unit += styles[i % styles.count] + String(UnicodeScalar(start+i)!)
            if i % 80 == 79 { unit += "\r\n" }
        }
        unit += "\u{1b}[0m"
    }
    for _ in 0..<iterations { try write(unit) }
}
try file.close()
let bytes = try Data(contentsOf: output)
let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
try JSONSerialization.data(withJSONObject: ["case": name, "sha256": digest, "bytes": bytes.count], options: [.sortedKeys])
    .write(to: URL(fileURLWithPath: output.path + ".json"))
