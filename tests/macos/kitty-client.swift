// A direct-transport Kitty client for native PTY smoke tests. The launcher must
// put its PTY into raw, no-echo mode before starting this executable.
import Foundation
import Darwin

guard CommandLine.arguments.count == 2 else { fatalError("usage: kitty-client image.png") }
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
func output(_ text: String) throws {
    try FileHandle.standardOutput.write(contentsOf: Data(text.utf8))
}
func readByte() -> UInt8 {
    var byte: UInt8 = 0
    while true {
        let count = read(STDIN_FILENO, &byte, 1)
        if count == 1 { return byte }
        if count < 0 && errno == EINTR { continue }
        fatalError("expected input byte, got EOF or read error")
    }
}
func ack(_ id: Int) {
    var response: [UInt8] = []
    repeat { response.append(readByte()) } while response.last != 92
    let expected = "\u{1b}_Gi=\(id);OK\u{1b}\\"
    guard response == Array(expected.utf8) else {
        fatalError("expected \(expected.debugDescription), got \(String(decoding: response, as: UTF8.self).debugDescription)")
    }
}
try output("\u{1b}_Ga=q,t=d,f=24,s=1,v=1,i=100;/wAA\u{1b}\\")
ack(100)
try output("\u{1b}[2J\u{1b}[HKitty PNG transfer\r\n\u{1b}[3;3H")
let encoded = Array(data.base64EncodedString().utf8)
for offset in stride(from: 0, to: encoded.count, by: 4096) {
    let end = min(offset + 4096, encoded.count)
    var header = "m=\(end < encoded.count ? 1 : 0)"
    if offset == 0 { header = "a=T,t=d,f=100,i=101,c=32,r=12,C=1," + header }
    try output("\u{1b}_G\(header);\(String(decoding: encoded[offset..<end], as: UTF8.self))\u{1b}\\")
}
ack(101)
try output("\u{1b}[17;1HPNG ACK received\u{1b}]2;Kitty displayed\u{7}")
guard readByte() == 100 else { fatalError("expected delete command") }
try output("\u{1b}_Ga=d,d=I,i=101\u{1b}\\\u{1b}[17;1H" + String(repeating: " ", count: 24) + "\rImage deleted\u{1b}]2;Kitty deleted\u{7}")
guard readByte() == 113 else { fatalError("expected quit command") }
