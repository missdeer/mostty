// macOS collector: PID-only footprint/resident, optional related PID samples.
import Foundation
import Darwin
import AppKit
import Metal

func run(_ path: String, _ arguments: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = arguments
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "unavailable" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
func memory(_ pid: Int32) -> [String: Any] {
    var usage = rusage_info_v4()
    let result = withUnsafeMutableBytes(of: &usage) {
        proc_pid_rusage(pid, RUSAGE_INFO_V4, $0.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self))
    }
    guard result == 0 else { return ["pid": pid, "status": "exited-or-unavailable", "errno": errno] }
    return ["pid": pid, "status": "ok", "physical_footprint_bytes": usage.ri_phys_footprint,
            "resident_bytes": usage.ri_resident_size, "cpu_ns": usage.ri_user_time + usage.ri_system_time,
            "package_idle_wakeups": usage.ri_pkg_idle_wkups, "interrupt_wakeups": usage.ri_interrupt_wkups]
}
func resources(_ pid: Int32, smoke: Bool) -> [String: Any] {
    guard !smoke, let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
          NSRunningApplication.runningApplications(withBundleIdentifier: bundle).count == 1 else {
        return ["status": "blocked", "reason": "Requires one target Mostty app instance and Apple Events permission", "data": NSNull()]
    }
    // Bundle ID comes from NSRunningApplication, never from command text.
    guard !bundle.contains("\"") && !bundle.contains("\\"),
          let script = NSAppleScript(source: "with timeout of 10 seconds\ntell application id \"\(bundle)\" to get resource data of terminals\nend timeout") else {
        return ["status": "blocked", "reason": "Invalid target bundle", "data": NSNull()]
    }
    var error: NSDictionary?
    let reply = script.executeAndReturnError(&error)
    guard error == nil else { return ["status": "blocked", "reason": String(describing: error!), "data": NSNull()] }
    var panes: [[String: Any]] = []
    if reply.numberOfItems > 0 {
        for index in 1...reply.numberOfItems {
            guard let text = reply.atIndex(index)?.stringValue,
                  let data = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], data["schema"] as? Int == 1 else {
                return ["status": "blocked", "reason": "Target resource API unavailable", "data": NSNull()]
            }
            panes.append(data)
        }
    }
    let visible = panes.filter { ($0["host"] as? [String: Any])?["visible"] as? Bool == true }.count
    return ["status": "ok", "data": ["schema": 1, "pane_count": panes.count, "active_panes": visible,
            "hidden_panes": panes.count - visible, "panes": panes]]
}

let args = CommandLine.arguments
let smoke = args.count >= 3 && args[1] == "--smoke"
guard (smoke && args.count == 3) || (!smoke && args.count == 6),
      let pid = smoke ? getpid() : Int32(args[1]),
      let samples = smoke ? 2 : Int(args[4]), let interval = smoke ? 50 : Int(args[5]), samples >= 2, interval >= 10 else {
    fatalError("usage: collect PID metadata.json output.jsonl samples interval-ms | --smoke output.jsonl")
}
let output = URL(fileURLWithPath: smoke ? args[2] : args[3])
var meta: [String: Any]
if smoke {
    meta = ["commit": run("/usr/bin/git", ["rev-parse", "HEAD"]), "compiler": run("/usr/bin/env", ["zig", "version"]),
            "mode": "collector-smoke", "target_cpu": run("/usr/bin/uname", ["-m"]), "backend": "collector-self", "presentation": NSNull(),
            "font": "not-applicable", "font_size_pt": 0, "dpi": 0, "window_pixels": [0, 0], "panes": 0,
            "dependencies": run("/usr/bin/shasum", ["-a", "256", "build.zig.zon"]).components(separatedBy: " ")[0],
            "conpty_version": "not-applicable", "input_sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            "scenario": "collector-smoke", "phase": "smoke", "side": "head", "trial": 0, "run_group": "smoke",
            "steady_samples": samples, "warmup_seconds": 0]
} else {
    meta = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [String: Any]
}
for key in ["commit","compiler","mode","target_cpu","backend","font","font_size_pt","dpi","window_pixels","panes","dependencies","conpty_version","input_sha256","scenario","side","trial","run_group","phase","steady_samples","warmup_seconds"] {
    precondition(meta[key] != nil, "Missing metadata: \(key)")
}
precondition(meta["presentation"] != nil, "Missing presentation metadata")
meta["kind"] = "metadata"; meta["schema"] = 1; meta["platform"] = "macOS"; meta["pid"] = pid
meta["role"] = smoke ? "smoke" : "measurement"; meta["samples"] = samples; meta["interval_ms"] = interval
meta["scope"] = "Target PID only; shell excluded. related_pids are reported separately. Metal device bytes overlap pane snapshots."
meta["hardware"] = ["os": ProcessInfo.processInfo.operatingSystemVersionString,
    "cpu": run("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]),
    "gpu": MTLCopyAllDevices().map { ["name": $0.name, "registry_id": $0.registryID, "unified_memory": $0.hasUnifiedMemory] as [String: Any] }]
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
_ = FileManager.default.createFile(atPath: output.path, contents: nil)
let file = try FileHandle(forWritingTo: output)
defer { try? file.close() }
func emit(_ value: [String: Any]) throws {
    var bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); bytes.append(10)
    try file.write(contentsOf: bytes)
}
try emit(meta)
Thread.sleep(forTimeInterval: (meta["warmup_seconds"] as? Double) ?? 0)
let epoch = DispatchTime.now().uptimeNanoseconds
for index in 0..<samples {
    autoreleasepool {
        let start = DispatchTime.now().uptimeNanoseconds
        let os = memory(pid)
        let probe = DispatchTime.now().uptimeNanoseconds
        let app = resources(pid, smoke: smoke)
        let end = DispatchTime.now().uptimeNanoseconds
        let related = (meta["related_pids"] as? [NSNumber] ?? []).map { memory($0.int32Value) }
        try! emit(["kind": "sample", "index": index, "elapsed_ns": end - epoch, "phase": meta["phase"]!,
                   "os": os, "app": app, "related": related, "probe_ns": end - probe,
                   "gpu": ["status": "blocked", "reason": "Metal allocated size is app device scope; see pane renderer snapshots",
                           "dedicated_bytes": NSNull(), "shared_bytes": NSNull()]])
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        if index + 1 < samples { Thread.sleep(forTimeInterval: max(0, Double(interval) / 1000 - elapsed)) }
    }
}
