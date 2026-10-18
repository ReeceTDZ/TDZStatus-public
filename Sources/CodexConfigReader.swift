import Foundation

struct CodexConfigSummary {
    let activeProviders: [String]
    let declaredProviders: [String]
    let configPath: String

    static func read() -> CodexConfigSummary {
        let environment = ProcessInfo.processInfo.environment
        let home = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        let url = home.appendingPathComponent("config.toml")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return CodexConfigSummary(activeProviders: [], declaredProviders: [], configPath: url.path)
        }

        var active = Set<String>()
        var declared = Set<String>()
        let activeProviderPattern = try? NSRegularExpression(
            pattern: #"^\s*model_provider\s*=\s*["']([^"']+)["']"#
        )
        let tablePattern = try? NSRegularExpression(
            pattern: #"^\s*\[\s*model_providers\."?([A-Za-z0-9_.-]+)"?\s*\]\s*(?:#.*)?$"#
        )

        for line in contents.components(separatedBy: .newlines) {
            guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") else { continue }
            let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = activeProviderPattern?.firstMatch(in: line, range: fullRange),
               let range = Range(match.range(at: 1), in: line) {
                active.insert(String(line[range]))
            }
            if let match = tablePattern?.firstMatch(in: line, range: fullRange),
               let range = Range(match.range(at: 1), in: line) {
                declared.insert(String(line[range]))
            }
        }

        return CodexConfigSummary(
            activeProviders: active.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
            declaredProviders: declared.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
            configPath: url.path
        )
    }
}
