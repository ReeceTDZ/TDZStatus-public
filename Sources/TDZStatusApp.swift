import AppKit
import ImageIO
import SwiftUI

private struct GIFFrames {
    var images: [NSImage]
    var delays: [TimeInterval]
}

@main
@MainActor
final class TDZStatusApp: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = TDZStatusModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem!
    private var animationTimer: Timer?
    private var animations: [HarnessKind: [HarnessActivity: GIFFrames]] = [:]
    private var idleImages: [HarnessKind: NSImage] = [:]
    private var currentKey: String?
    private var currentFrameIndex = 0
    private var currentFrameStartedAt = Date()
    private var deactivationObserver: NSObjectProtocol?

    static func main() {
        let app = NSApplication.shared
        let delegate = TDZStatusApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.toolTip = "TDZStatus · harness and usage monitor"
        statusItem.button?.imagePosition = .imageOnly

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 640, height: 680)
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: DashboardView(model: model))
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }

        loadAssets()
        model.start()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateStatusIcon() }
        }
        updateStatusIcon()

        if model.showOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                NSApp.activate(ignoringOtherApps: true)
                self.showPopover()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        animationTimer?.invalidate()
        model.stop()
        if let deactivationObserver {
            NotificationCenter.default.removeObserver(deactivationObserver)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refreshAll()
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        button.highlight(true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.becomeKey()
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let harness = model.iconHarness
        let activity = model.animationActivity(for: harness)
        let key = "\(harness.rawValue):\(activity.rawValue)"
        let color = harness.accent

        if activity == .idle {
            let image = idleImages[harness] ?? fallbackImage(for: harness)
            image.isTemplate = true
            button.image = image
            button.contentTintColor = NSColor(calibratedRed: 0.27, green: 0.70, blue: 0.48, alpha: 1)
            currentKey = key
            return
        }

        guard let gif = animations[harness]?[activity], !gif.images.isEmpty else {
            let image = NSImage(systemSymbolName: harness.symbol, accessibilityDescription: "\(harness.title) is \(activity.title.lowercased())")
                ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: "TDZStatus")!
            image.isTemplate = false
            button.image = image
            button.contentTintColor = color
            return
        }

        if currentKey != key {
            currentKey = key
            currentFrameIndex = 0
            currentFrameStartedAt = Date()
        }
        let delay = gif.delays.indices.contains(currentFrameIndex) ? gif.delays[currentFrameIndex] : 0.08
        if Date().timeIntervalSince(currentFrameStartedAt) >= delay {
            currentFrameIndex = (currentFrameIndex + 1) % gif.images.count
            currentFrameStartedAt = Date()
        }
        button.image = gif.images[currentFrameIndex]
        button.image?.isTemplate = false
        button.contentTintColor = color
    }

    private func loadAssets() {
        for harness in HarnessKind.allCases {
            let folder: String
            let idleName: String
            let thinkingName: String
            let workingName: String
            switch harness {
            case .zcode:
                folder = "ZCode"
                idleName = "ZCode_symbol.svg"
                thinkingName = "Thinking.GIF"
                workingName = "RunningCommandOrResponding.gif"
            case .claude:
                folder = "Claude"
                idleName = "Claude_AI_symbol.svg"
                thinkingName = "Thinking.GIF"
                workingName = "RunningCommandOrResponding.gif"
            case .codex:
                folder = "Codex"
                idleName = "CodexStatus_symbol.svg"
                thinkingName = "CodexThinking.gif"
                workingName = "CodexWorking.gif"
            }

            if let idleURL = assetURL(folder: folder, file: idleName), let image = NSImage(contentsOf: idleURL) {
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = true
                idleImages[harness] = image
            }
            if let thinkingURL = assetURL(folder: folder, file: thinkingName),
               let frames = decodeGIF(at: thinkingURL) {
                animations[harness, default: [:]][.thinking] = frames
            }
            if let workingURL = assetURL(folder: folder, file: workingName),
               let frames = decodeGIF(at: workingURL) {
                animations[harness, default: [:]][.working] = frames
            }
        }
    }

    private func assetURL(folder: String, file: String) -> URL? {
        if let root = Bundle.main.resourceURL {
            let bundled = root.appendingPathComponent("Assets", isDirectory: true)
                .appendingPathComponent(folder, isDirectory: true)
                .appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Assets/\(folder)/\(file)")
    }

    private func decodeGIF(at url: URL) -> GIFFrames? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        var images: [NSImage] = []
        var delays: [TimeInterval] = []
        for index in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            images.append(NSImage(cgImage: cgImage, size: NSSize(width: 18, height: 18)))
            var delay = 0.09
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
               let gif = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any],
               let value = gif[kCGImagePropertyGIFDelayTime as String] as? Double {
                delay = max(0.025, value * 0.8)
            }
            delays.append(delay)
        }
        return images.isEmpty ? nil : GIFFrames(images: images, delays: delays)
    }

    private func fallbackImage(for harness: HarnessKind) -> NSImage {
        let image = NSImage(systemSymbolName: harness.symbol, accessibilityDescription: harness.title)
            ?? NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: "TDZStatus")!
        image.isTemplate = true
        return image
    }
}
