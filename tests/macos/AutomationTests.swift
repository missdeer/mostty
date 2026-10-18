import AppKit
import AppIntents
import ObjectiveC

@main
struct AutomationTests {
    static func main() throws {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        let bundleURL = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let bundle = Bundle(url: bundleURL) else { fatalError("Missing Mostty bundle") }
        NSScriptSuiteRegistry.shared().loadSuites(from: bundle)
        // Noninteractive Mostty launchers export an empty override. A new app
        // must still discover the resources in its own bundle.
        setenv("MOSTTY_RESOURCES_DIR", "", 1)
        setenv("SHELL", "/bin/zsh", 1)
        setenv("ZDOTDIR", FileManager.default.currentDirectoryPath + "/tests/macos/shell-startup", 1)
        let model = AppModel.shared
        defer { model.shutdownAll() }
        let window = NSWindow(contentRect: NSRect(x: 60, y: 80, width: 1200, height: 800),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = ContentView(model: model, frame: window.contentView!.bounds)
        window.makeKeyAndOrderFront(nil)
        var failures = 0
        func expect(_ condition: Bool, _ rule: String) {
            print("\(condition ? "PASS" : "FAIL"): \(rule)")
            if !condition { failures += 1 }
        }
        func waitUntil(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                window.contentView?.layoutSubtreeIfNeeded()
            }
            return condition()
        }
        expect(waitUntil { model.selectedTab?.activePane?.view.atPrompt == true },
               "an empty inherited resource override still loads the bundled shell integration")
        let first = model.selectedTab!.activePane!
        try TerminalAutomation.input("cd /usr\r", to: first.automationID)
        expect(waitUntil { first.view.workingDirectory == "/usr" && first.view.atPrompt },
               "OSC 7 reaches the host after an interactive cd")
        let inherited = try TerminalAutomation.newTab()
        expect(waitUntil { inherited.view.workingDirectory == "/usr" },
               "new tabs inherit the live shell directory")
        let oldID = first.automationID
        try TerminalAutomation.focus(oldID)
        expect(model.selectedTab?.activePane === first, "automation resolves stable pane IDs across tab switches")
        let tabsBeforeFailure = model.tabs.map(\.id)
        let selectedBeforeFailure = model.selectedID
        setenv("SHELL", "/definitely/missing/mostty-review-shell", 1)
        do {
            _ = try TerminalAutomation.newTab(directory: "/usr")
            expect(false, "a real shell exec failure is reported to automation")
        } catch {
            expect(model.tabs.map(\.id) == tabsBeforeFailure && model.selectedID == selectedBeforeFailure,
                   "a failed automated tab start removes the new tab and restores selection")
        }
        setenv("SHELL", "/bin/zsh", 1)
        let shortCommand = try TerminalAutomation.newTab(directory: "/usr", command: "exit 0")
        // Keep the main queue paused so EOF cleanup cannot remove the view:
        // process liveness must be independent of successful session creation.
        let exitDeadline = Date().addingTimeInterval(5)
        while shortCommand.view.hasActiveSession && Date() < exitDeadline { usleep(1000) }
        expect(!shortCommand.view.hasActiveSession && shortCommand.view.hasStartedSession,
               "a successfully started short command is not reported as a launch failure after it exits")
        try TerminalAutomation.focus(oldID)
        expect(waitUntil { !model.tabs.contains { $0.panes.contains { $0 === shortCommand } } },
               "a short command still receives normal EOF cleanup")
        do {
            try TerminalAutomation.focus("4294967295")
            expect(false, "stale IDs produce an error")
        } catch { expect(true, "stale IDs produce an error") }
        expect(TerminalDirectory.localPath("file://remote.invalid/usr", host: "local") == nil,
               "remote shell paths never become local launch directories")
        expect(TerminalDirectory.localPath("file://localhost/a%20b", host: "local") == "/a b" &&
               TerminalDirectory.localPath("kitty-shell-cwd://local/a%20b", host: "local") == "/a%20b",
               "file URIs decode escapes while kitty-shell-cwd preserves literal percent signs")

        func script(_ body: String) throws -> NSAppleEventDescriptor {
            let source = "using terms from application \"\(bundleURL.path)\"\n tell current application\n\(body)\n end tell\nend using terms from"
            var error: NSDictionary?
            let result = NSAppleScript(source: source)!.executeAndReturnError(&error)
            if let error = error { throw NSError(domain: "AppleScript", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(error)"]) }
            return result
        }
        let ids = try script("get id of terminals")
        expect(ids.numberOfItems == TerminalAutomation.terminals.count,
               "AppleScript enumerates real terminal panes through the published dictionary")
        _ = try script("focus terminal \"\(inherited.automationID)\"")
        expect(model.selectedTab?.activePane === inherited, "AppleScript focus command reaches the model")
        let previousCount = TerminalAutomation.terminals.count
        let created = try script("get id of (new tab working directory \"/usr\")")
        expect(created.stringValue != nil && TerminalAutomation.terminals.count == previousCount + 1,
               "AppleScript can create a terminal and dereference its returned object")
        try TerminalAutomation.focus(inherited.automationID)
        let selectedBeforeInvalidArgument = model.selectedID
        do {
            _ = try script("focus terminal (first terminal)")
            expect(false, "a terminal object cannot silently replace the documented text ID")
        } catch {
            expect(model.selectedID == selectedBeforeInvalidArgument,
                   "an invalid AppleScript terminal argument fails without targeting the active pane")
        }

        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/automation-input-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try script("input text \"printf script-ok > '\(output.path)'\" & return to terminal \"\(oldID)\"")
        expect(waitUntil { (try? String(contentsOf: output, encoding: .utf8)) == "script-ok" },
               "AppleScript input text sends the exact command to its named terminal")
        _ = try script("get id of (split terminal \"\(oldID)\" direction \"right\")")
        expect(model.selectedTab?.panes.count == 2, "AppleScript split creates an independent pane")
        let cancel: @convention(c) (NSAlert, Selector) -> Int = { _, _ in NSApplication.ModalResponse.alertFirstButtonReturn.rawValue }
        let method = class_getInstanceMethod(NSAlert.self, #selector(NSAlert.runModal))!
        let original = method_setImplementation(method, unsafeBitCast(cancel, to: IMP.self))
        defer { method_setImplementation(method, original) }
        var intentFinished = false
        Task { @MainActor in
            do {
                let suggestions = try await TerminalQuery().suggestedEntities()
                expect(suggestions.contains { $0.id == oldID }, "App Intents queries expose live stable terminal IDs")
                let create = NewTabIntent()
                create.directory = "/usr"
                let created = try await create.perform()
                guard let entity = created.value else { throw TerminalAutomation.Failure("New Tab intent returned no terminal entity") }
                expect(TerminalAutomation.terminals.contains { $0.automationID == entity.id },
                       "New Tab intent returns a live terminal entity for later actions")
                let details = GetTerminalDetailsIntent()
                details.terminal = TerminalEntity(first)
                let detailResult = try await details.perform()
                expect(detailResult.value?.contains("/usr") == true, "Get Details intent returns the reported local directory")
                let close = CloseTerminalIntent()
                close.terminal = entity
                if mostty_config_confirm_close() {
                    do {
                        _ = try await close.perform()
                        expect(false, "Close Terminal intent reports cancellation")
                    } catch {
                        expect(TerminalAutomation.terminals.contains { $0.automationID == entity.id },
                               "Close Terminal intent preserves the pane when confirmation is cancelled")
                    }
                } else {
                    _ = try await close.perform()
                    expect(!TerminalAutomation.terminals.contains { $0.automationID == entity.id },
                           "Close Terminal intent honors disabled confirmation")
                }
                let focus = FocusTerminalIntent()
                focus.terminal = TerminalEntity(first)
                _ = try await focus.perform()
                expect(model.selectedTab?.activePane === first, "Focus Terminal intent operates on the selected entity")
                let input = InputTextIntent()
                input.terminal = TerminalEntity(first)
                input.text = "printf intent-ok > '\(output.path)'\r"
                _ = try await input.perform()
                let split = SplitTerminalIntent()
                split.terminal = TerminalEntity(first)
                split.direction = .down
                let before = TerminalAutomation.terminals.count
                _ = try await split.perform()
                expect(TerminalAutomation.terminals.count == before + 1,
                       "Split Terminal intent creates a real independent PTY pane")
            } catch {
                expect(false, "App Intent execution: \(error)")
            }
            intentFinished = true
        }
        expect(waitUntil { intentFinished }, "App Intent handlers complete on the main actor")
        expect(waitUntil { (try? String(contentsOf: output, encoding: .utf8)) == "intent-ok" },
               "Input Text intent reaches the shell and executes the requested bytes")

        if mostty_config_confirm_close() {
            do {
                try TerminalAutomation.close(oldID)
                expect(false, "automation honors close cancellation")
            } catch {
                expect(TerminalAutomation.terminals.contains { $0.automationID == oldID },
                       "automation honors close cancellation without dropping the pane")
            }
        } else {
            try TerminalAutomation.close(oldID)
            expect(!TerminalAutomation.terminals.contains { $0.automationID == oldID },
                   "automation honors configuration that disables close confirmation")
        }
        withExtendedLifetime(delegate) {}
        exit(failures == 0 ? 0 : 1)
    }
}
