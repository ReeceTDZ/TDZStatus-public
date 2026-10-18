import Foundation

private struct CodexBridgeEnvelope: Decodable {
    struct Window: Decodable {
        var id: String
        var title: String
        var usedPercentage: Double
        var windowDurationMinutes: Int?
        var resetsAt: Double?
    }

    var accountName: String?
    var planName: String?
    var windows: [Window]?
    var fetchedAt: Double?
    var error: String?
}

final class CodexUsageBridge {
    private let pythonCandidates = [
        "/usr/bin/python3",
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
    ]

    func fetch(completion: @escaping (Result<CodexUsageSnapshot, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            do {
                let output = try self.runBridge()
                let envelope = try JSONDecoder().decode(CodexBridgeEnvelope.self, from: output)
                if let error = envelope.error {
                    throw CodexBridgeError.unavailable(error)
                }
                let windows = (envelope.windows ?? []).map { window in
                    CodexQuotaWindow(
                        id: window.id,
                        title: window.title,
                        usedPercentage: min(100, max(0, window.usedPercentage)),
                        windowDurationMinutes: window.windowDurationMinutes,
                        resetsAt: window.resetsAt.map(Date.init(timeIntervalSince1970:))
                    )
                }
                guard !windows.isEmpty else {
                    throw CodexBridgeError.unavailable("Codex returned no usage windows.")
                }
                let snapshot = CodexUsageSnapshot(
                    accountName: envelope.accountName,
                    planName: envelope.planName,
                    windows: windows,
                    fetchedAt: Date(timeIntervalSince1970: envelope.fetchedAt ?? Date().timeIntervalSince1970)
                )
                DispatchQueue.main.async { completion(.success(snapshot)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func runBridge() throws -> Data {
        guard let pythonPath = pythonCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CodexBridgeError.unavailable("Python 3 wasn't found for the local Codex app-server bridge.")
        }
        guard let script = bridgeScriptURL(), FileManager.default.isReadableFile(atPath: script.path) else {
            throw CodexBridgeError.unavailable("The Codex usage bridge is missing from the app bundle.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [script.path]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        if environment["CODEX_HOME"] == nil {
            environment["CODEX_HOME"] = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true).path
        }
        process.environment = environment

        do {
            try process.run()
        } catch {
            throw CodexBridgeError.unavailable("Couldn't start the local Codex app-server bridge: \(error.localizedDescription)")
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 25) {
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw CodexBridgeError.unavailable("Codex app-server exited with status \(process.terminationStatus).")
        }
        guard !data.isEmpty else {
            throw CodexBridgeError.unavailable("Codex app-server didn't return usage data.")
        }
        return data
    }

    private func bridgeScriptURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "codex_usage_bridge", withExtension: "py") {
            return bundled
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/codex_usage_bridge.py")
    }
}

private enum CodexBridgeError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        }
    }
}
