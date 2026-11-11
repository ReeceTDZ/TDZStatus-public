import AppKit
import CoreWLAN
import CoreFoundation
import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt
import Network
import Security
import ServiceManagement
import UserNotifications

struct CodexTokenUsageSnapshot {
    var cumulativeTokens: Int64
    var latestTurnTokens: Int64
    var model: String?
    var observedAt: Date
}

/// Reads only Codex's numeric token_count records. Prompt, response, and tool
/// records are skipped before JSON decoding.
struct CodexTokenUsageReader {
    private let sessionsDirectory: URL

    init() {
        let environment = ProcessInfo.processInfo.environment
        let codexHome = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        sessionsDirectory = codexHome.appendingPathComponent("sessions", isDirectory: true)
    }

    func read() -> CodexTokenUsageSnapshot? {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let files = (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modified = values.contentModificationDate,
                      modified >= cutoff else { return nil }
                return (url, modified)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(80)

        let marker = Data(#""type":"token_count""#.utf8)
        var latestBySession: [String: CodexTokenUsageSnapshot] = [:]

        for (url, _) in files {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            let start = size > 512 * 1024 ? size - 512 * 1024 : 0
            try? handle.seek(toOffset: start)
            guard let tail = try? handle.readToEnd() else { continue }

            for (index, line) in tail.split(separator: 10, omittingEmptySubsequences: true).enumerated() {
                if start > 0 && index == 0 { continue }
                guard Data(line).range(of: marker) != nil,
                      let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let timestamp = record["timestamp"] as? String,
                      let observedAt = Self.parseDate(timestamp),
                      let payload = record["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any] else { continue }

                let totals = info["total_token_usage"] as? [String: Any]
                let last = info["last_token_usage"] as? [String: Any]
                guard let totalTokens = Self.integer(totals?["total_tokens"]) else { continue }
                let snapshot = CodexTokenUsageSnapshot(
                    cumulativeTokens: totalTokens,
                    latestTurnTokens: Self.integer(last?["total_tokens"]) ?? 0,
                    model: record["model"] as? String,
                    observedAt: observedAt
                )
                let sessionKey = url.path
                if latestBySession[sessionKey].map({ $0.observedAt < observedAt }) ?? true {
                    latestBySession[sessionKey] = snapshot
                }
            }
        }

        guard !latestBySession.isEmpty else { return nil }
        let latest = latestBySession.values.max { $0.observedAt < $1.observedAt }!
        return CodexTokenUsageSnapshot(
            cumulativeTokens: latestBySession.values.reduce(0) { $0 + $1.cumulativeTokens },
            latestTurnTokens: latest.latestTurnTokens,
            model: latest.model,
            observedAt: latest.observedAt
        )
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.int64Value
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

final class TDZStatusNotificationCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TDZStatusNotificationCenter()
    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorizationIfNeeded(completion: @escaping () -> Void = {}) {
        center.getNotificationSettings { [weak self] settings in
            guard let self else {
                completion()
                return
            }
            guard settings.authorizationStatus == .notDetermined else {
                completion()
                return
            }
            self.center.requestAuthorization(options: [.alert, .sound]) { _, _ in completion() }
        }
    }

    func send(title: String, body: String, identifier: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request) { error in
            guard error != nil else { return }
            Self.sendViaAppleScript(title: title, body: body)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    private static func sendViaAppleScript(title: String, body: String) {
        func escaped(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let script = "display notification \"\(escaped(body))\" with title \"\(escaped(title))\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

enum TDZLaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

enum HotspotCredentialError: LocalizedError {
    case emptySSID
    case emptyPassword
    case missingCredential
    case keychain(String)
    case wifiUnavailable
    case networkNotFound(String)

    var errorDescription: String? {
        switch self {
        case .emptySSID: "Enter your phone hotspot's network name."
        case .emptyPassword: "Enter the password for this hotspot."
        case .missingCredential: "The saved hotspot password is unavailable. Re-enter it in Settings."
        case .keychain(let reason): "Couldn't save the hotspot password in Keychain: \(reason)"
        case .wifiUnavailable: "The Mac's Wi-Fi interface is unavailable."
        case .networkNotFound(let ssid): "The hotspot ‘\(ssid)’ isn't visible yet."
        }
    }
}

final class HotspotCredentialStore {
    private let service = "com.reecedove.tdzstatus.public.phone-hotspot"
    private let legacyServices = ["ZCodeStatus Hotspot", "CodexStatus Hotspot", "ClaudeStatus Hotspot"]

    func save(password: String, for ssid: String) throws {
        let account = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty else { throw HotspotCredentialError.emptySSID }
        guard !password.isEmpty else { throw HotspotCredentialError.emptyPassword }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: Data(password.utf8)]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(password.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw HotspotCredentialError.keychain(Self.keychainMessage(addStatus))
            }
        } else if status != errSecSuccess {
            throw HotspotCredentialError.keychain(Self.keychainMessage(status))
        }
    }

    func password(for ssid: String) throws -> String {
        for serviceName in [service] + legacyServices {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: ssid,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess, let data = result as? Data,
                  let password = String(data: data, encoding: .utf8) else {
                throw HotspotCredentialError.keychain(Self.keychainMessage(status))
            }
            return password
        }
        throw HotspotCredentialError.missingCredential
    }

    private static func keychainMessage(_ status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
}

enum PhoneHotspotConnector {
    static func connect(ssid: String, password: String) throws {
        guard let interface = CWWiFiClient.shared().interface() else {
            throw HotspotCredentialError.wifiUnavailable
        }
        let networks = try interface.scanForNetworks(withName: ssid)
        guard let network = networks.first(where: { $0.ssid == ssid }) else {
            throw HotspotCredentialError.networkNotFound(ssid)
        }
        try interface.associate(to: network, password: password)
    }
}

@MainActor
final class CodeSleepController {
    private struct PausedProcess: Codable {
        var pid: Int32
        var bundleIdentifier: String
    }

    private var assertionIDs: [IOPMAssertionID] = []
    private var pausedProcesses: [PausedProcess] = []
    private let stateURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TDZStatus/paused-processes.json")

    init() {
        resumeProcessesLeftByPreviousRun()
    }

    var isHolding: Bool { !assertionIDs.isEmpty }

    func update(shouldHold: Bool, pauseOtherApps: Bool) {
        if shouldHold {
            if assertionIDs.isEmpty { acquireAssertions() }
            if isHolding && pauseOtherApps {
                pauseApplications()
            } else if !pauseOtherApps {
                resumeApplications()
            }
        } else {
            release()
        }
    }

    func release() {
        resumeApplications()
        for assertion in assertionIDs { IOPMAssertionRelease(assertion) }
        assertionIDs.removeAll()
    }

    private func acquireAssertions() {
        let types: [String] = [
            kIOPMAssertionTypePreventUserIdleSystemSleep,
            kIOPMAssertionTypePreventSystemSleep,
        ]
        for type in types {
            var assertion = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "TDZStatus Code Sleep" as CFString,
                &assertion
            )
            if result == kIOReturnSuccess { assertionIDs.append(assertion) }
        }
    }

    private func pauseApplications() {
        let excludedNames = ["finder", "dock", "systemuiserver", "controlcenter", "spotlight",
                             "windowserver", "loginwindow", "tdzstatus", "zcode", "claude", "codex", "chatgpt"]
        let excludedBundlePrefixes = ["com.apple.", "com.reecedove.tdzstatus.public", "com.reecedove.zcodestatus",
                                      "com.anthropic.", "com.openai."]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let name = app.localizedName?.lowercased(),
                  !excludedNames.contains(where: { name.contains($0) }),
                  let bundleID = app.bundleIdentifier,
                  !excludedBundlePrefixes.contains(where: { bundleID.lowercased().hasPrefix($0) }),
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  !pausedProcesses.contains(where: { $0.pid == app.processIdentifier }) else { continue }
            if kill(app.processIdentifier, SIGSTOP) == 0 {
                pausedProcesses.append(PausedProcess(pid: app.processIdentifier, bundleIdentifier: bundleID))
            }
        }
        persistPausedProcesses()
    }

    private func resumeApplications() {
        for process in pausedProcesses { resume(process) }
        pausedProcesses.removeAll()
        try? FileManager.default.removeItem(at: stateURL)
    }

    private func resumeProcessesLeftByPreviousRun() {
        guard let data = try? Data(contentsOf: stateURL),
              let saved = try? JSONDecoder().decode([PausedProcess].self, from: data) else { return }
        for process in saved { resume(process) }
        try? FileManager.default.removeItem(at: stateURL)
    }

    private func resume(_ process: PausedProcess) {
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.processIdentifier == process.pid && $0.bundleIdentifier == process.bundleIdentifier
        }) else { return }
        _ = kill(running.processIdentifier, SIGCONT)
    }

    private func persistPausedProcesses() {
        guard let data = try? JSONEncoder().encode(pausedProcesses) else { return }
        let directory = stateURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: stateURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }
}

func formattedTokenCount(_ value: Int64) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
}
