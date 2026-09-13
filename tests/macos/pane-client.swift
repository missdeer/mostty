// Real PTY probe: periodic output, live terminal dimensions, and raw input log.
import Foundation
import Darwin

guard CommandLine.arguments.count == 3 else {
    fatalError("usage: pane-client name directory")
}
let name = CommandLine.arguments[1]
let directory = URL(fileURLWithPath: CommandLine.arguments[2])
var original = termios()
guard tcgetattr(STDIN_FILENO, &original) == 0 else { fatalError("tcgetattr failed") }
var raw = original
cfmakeraw(&raw)
guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { fatalError("tcsetattr failed") }
defer { tcsetattr(STDIN_FILENO, TCSANOW, &original) }

func output(_ text: String) throws {
    try FileHandle.standardOutput.write(contentsOf: Data(text.utf8))
}
func title() throws {
    var size = winsize()
    guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 else { fatalError("TIOCGWINSZ failed") }
    try output("\u{1b}]2;\(name):\(getpid()):\(size.ws_row):\(size.ws_col)\u{7}")
}
// The signal handler only sets a flag; terminal queries and output run in the loop.
var resized: sig_atomic_t = 0
signal(SIGWINCH) { _ in resized = 1 }
try title()
try Data(String(getpid()).utf8).write(to: directory.appendingPathComponent(name + ".pid"))
let logURL = directory.appendingPathComponent(name + ".input")
try Data().write(to: logURL)
let log = try FileHandle(forWritingTo: logURL)
defer { try? log.close() }
var tick = 0
var paused = false
var buffer = [UInt8](repeating: 0, count: 4096)
while true {
    if resized != 0 {
        resized = 0
        try title()
    }
    var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    let ready = poll(&descriptor, 1, 100)
    if ready < 0 {
        if errno == EINTR { continue }
        fatalError("poll failed")
    }
    if ready > 0 {
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        if count < 0 {
            if errno == EINTR { continue }
            fatalError("read failed")
        }
        if count == 0 || buffer.prefix(count).contains(4) { break }
        let data = Data(buffer.prefix(count))
        try log.write(contentsOf: data)
        switch String(decoding: data, as: UTF8.self) {
        case "M": try output("\u{1b}[?1003h\u{1b}[?1006h")
        case "B": try output("\u{1b}[?2004h")
        case "G":
            paused = true
            let pixels = Data(Array(repeating: [UInt8(255), 0, 0, 255], count: 4).flatMap { $0 }).base64EncodedString()
            try output("\u{1b}[2J\u{1b}[H\u{1b}_Ga=T,f=32,s=2,v=2,i=1,c=200,r=100,q=2;\(pixels)\u{1b}\\")
        case "C":
            paused = true
            try output("\u{1b}[2J\u{1b}[H")
        case "R": paused = false
        default: break
        }
    }
    if paused { continue }
    tick += 1
    try output("\(name) output \(tick)\r\n")
}
