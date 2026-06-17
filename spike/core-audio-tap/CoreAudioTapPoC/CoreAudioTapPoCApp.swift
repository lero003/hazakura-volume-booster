import AppKit
import Darwin
import SwiftUI

@main
struct CoreAudioTapPoCApp: App {
    @NSApplicationDelegateAdaptor(CoreAudioTapPoCAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class CoreAudioTapPoCAppDelegate: NSObject, NSApplicationDelegate {
    let engine = PoCAudioEngine()

    private var statusItemController: RightClickableStatusButton?
    private var sleepObserver: Any?
    private var wakeObserver: Any?
    private var screensWakeObserver: Any?
    private var lockFileDescriptor: CInt = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.isRunningUnderXCTest {
            engine.diagnosticLog.record(.info, "Single-instance lock skipped under XCTest")
        } else {
            guard acquireSingleInstanceLock() else {
                NSApplication.shared.terminate(nil)
                return
            }
        }

        statusItemController = RightClickableStatusButton(engine: engine)
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.engine.prepareForSleep()
            }
        }
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.engine.diagnosticLog.record(.info, "Workspace wake notification received")
                self?.engine.restoreAfterWake()
            }
        }
        screensWakeObserver = center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.engine.diagnosticLog.record(.info, "Screen wake notification received")
                self?.engine.restoreAfterWake()
            }
        }
        engine.diagnosticLog.record(.info, "App lifecycle observers installed")
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.shutdownForAppTermination()
        statusItemController?.invalidate()
        statusItemController = nil
        removeLifecycleObservers()
        releaseSingleInstanceLock()
    }

    private func acquireSingleInstanceLock() -> Bool {
        let lockPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("dev.keisetsu.hazakura-volume-booster.poc.lock")
        let descriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            engine.diagnosticLog.record(.warning, "Could not create single-instance lock; continuing without lock")
            return true
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            engine.diagnosticLog.record(.warning, "Second instance detected; terminating before audio startup")
            return false
        }

        lockFileDescriptor = descriptor
        engine.diagnosticLog.record(.info, "Single-instance lock acquired")
        return true
    }

    private func releaseSingleInstanceLock() {
        guard lockFileDescriptor >= 0 else { return }
        flock(lockFileDescriptor, LOCK_UN)
        close(lockFileDescriptor)
        lockFileDescriptor = -1
        engine.diagnosticLog.record(.info, "Single-instance lock released")
    }

    private func removeLifecycleObservers() {
        let center = NSWorkspace.shared.notificationCenter
        if let sleepObserver {
            center.removeObserver(sleepObserver)
        }
        if let wakeObserver {
            center.removeObserver(wakeObserver)
        }
        if let screensWakeObserver {
            center.removeObserver(screensWakeObserver)
        }
        sleepObserver = nil
        wakeObserver = nil
        screensWakeObserver = nil
    }

    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            NSClassFromString("XCTest.XCTestCase") != nil ||
            NSClassFromString("XCTestCase") != nil
    }
}

@MainActor
final class RightClickableStatusButton: NSObject {
    private let engine: PoCAudioEngine
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private lazy var quitMenu: NSMenu = makeQuitMenu()

    init(engine: PoCAudioEngine) {
        self.engine = engine
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        let hostingController = NSHostingController(rootView: ContentView(engine: engine))
        popover.contentViewController = hostingController
        popover.behavior = .transient

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Hazakura Amp!")
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(handleStatusButtonAction(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    func invalidate() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func handleStatusButtonAction(_ sender: NSStatusBarButton) {
        switch NSApplication.shared.currentEvent?.type {
        case .rightMouseUp:
            showQuitMenu(from: sender)
        default:
            togglePopover(from: sender)
        }
    }

    @objc private func quitFromMenu() {
        engine.shutdownForAppTermination()
        NSApplication.shared.terminate(nil)
    }

    private func togglePopover(from button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showQuitMenu(from button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        }
        quitMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }

    private func makeQuitMenu() -> NSMenu {
        let menu = NSMenu()
        let quitItem = NSMenuItem(title: "終了", action: #selector(quitFromMenu), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }
}
