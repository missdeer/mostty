import Foundation

enum MosttyCommandLine {
    static func run() -> Int32? {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--help"] || args == ["-h"] {
            print("""
            Usage: Mostty [options]
              --font-size <float>       Font size in points (1..256)
              --background-opacity <n>  Background opacity (0..1)
              --background-blur <bool>  Enable background blur (true/false)
              +list-themes              List available theme names
              +validate-config         Validate configuration without opening a window
              --config-file <path>     Configuration to validate
              --help                    Show this help
            """)
            return 0
        }
        if args == ["+list-themes"] {
            for index in 0..<mostty_config_refresh_themes() {
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = mostty_config_theme_name(index, &buffer, buffer.count)
                print(String(decoding: buffer.prefix(count), as: UTF8.self))
            }
            return 0
        }
        if args.first == "+validate-config" {
            if args.count == 1 { return mostty_config_validate_file(nil) }
            guard args.count == 3, args[1] == "--config-file" else { return fail("Expected +validate-config [--config-file <path>]") }
            return mostty_config_validate_file(args[2])
        }
        var font: Float = -1, opacity: Float = -1, blur: Int32 = -1
        var index = 0
        while index < args.count {
            let key = args[index]
            // Finder may supply a process serial number to an application.
            if key.hasPrefix("-psn_") { index += 1; continue }
            guard index + 1 < args.count else { return fail("Missing value for \(key)") }
            let value = args[index + 1]
            switch key {
            case "--font-size":
                guard let number = Float(value), number.isFinite, (1...256).contains(number) else { return fail("Invalid font size") }
                font = number
            case "--background-opacity":
                guard let number = Float(value), number.isFinite, (0...1).contains(number) else { return fail("Invalid opacity") }
                opacity = number
            case "--background-blur":
                guard ["true", "false"].contains(value.lowercased()) else { return fail("Invalid blur value") }
                blur = value.lowercased() == "true" ? 1 : 0
            default: return fail("Unknown option: \(key)")
            }
            index += 2
        }
        mostty_config_apply_cli(font, opacity, blur)
        return nil
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("Mostty: \(message)\n".utf8))
        return 2
    }
}
