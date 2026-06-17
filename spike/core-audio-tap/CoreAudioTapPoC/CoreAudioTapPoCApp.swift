import AppKit
import Darwin
import SwiftUI

@main
struct CoreAudioTapPoCApp: App {
    @NSApplicationDelegateAdaptor(CoreAudioTapPoCAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Hazakura Boost", systemImage: "speaker.wave.2.fill") {
            ContentView(engine: appDelegate.engine)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class CoreAudioTapPoCAppDelegate: NSObject, NSApplicationDelegate {
    let engine = PoCAudioEngine()

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
