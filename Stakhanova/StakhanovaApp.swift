import SwiftUI
import Combine

@main
struct StakhanovaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar only app - no main window
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem?
    var eventMonitor: EventMonitor?
    var captureService: CaptureService?

    var toggleMenuItem: NSMenuItem?
    var settingsWindow: NSWindow?
    var monitoringStatusWindow: NSWindow?
    private var monitoringStateSub: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize services
        captureService = CaptureService.shared
        eventMonitor = EventMonitor(captureService: captureService!)

        // Create menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Build menu
        statusItem?.menu = menu

        // Configure status item to show icon only (no text)
        if let button = statusItem?.button {
            // Use custom menu bar icon
            if let img = NSImage(named: "menubar_icon") {
                img.isTemplate = true // follows system tint (black/white based on theme)
                button.image = img
                button.imagePosition = .imageOnly
            }
        }
        statusItem?.length = NSStatusItem.squareLength

        // Keep menu label in sync with AppState
        setupMonitoringStateObserver()

        // Request permissions on first launch
        requestPermissions()
    }

    private lazy var menu: NSMenu = {
        let m = NSMenu()

        // Start / Stop Monitoring
        let t = NSMenuItem(title: "Start Monitoring",
                           action: #selector(toggleMonitoring),
                           keyEquivalent: "")
        t.target = self
        t.image = NSImage(systemSymbolName: "play.circle", accessibilityDescription: nil)
        m.addItem(t)
        self.toggleMenuItem = t

        m.addItem(NSMenuItem.separator())

        // Open Stakhanova (show main UI)
        let openMain = NSMenuItem(title: "Open Stakhanova…",
                                  action: #selector(openSettings),
                                  keyEquivalent: "o")
        openMain.target = self
        openMain.image = NSImage(systemSymbolName: "gear", accessibilityDescription: nil)
        m.addItem(openMain)

        // Open Captures Folder
        let openFolder = NSMenuItem(title: "Open Captures Folder…",
                                   action: #selector(openCapturesFolder),
                                   keyEquivalent: "f")
        openFolder.target = self
        openFolder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        m.addItem(openFolder)

        m.addItem(NSMenuItem.separator())

        // Quit
        let quit = NSMenuItem(title: "Quit Stakhanova",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApp
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        m.addItem(quit)

        return m
    }()

    func setupMonitoringStateObserver() {
        // Observe AppState.shared.isMonitoring to update menu title and icon
        monitoringStateSub = AppState.shared.$isMonitoring.sink { [weak self] isMonitoring in
            guard let self = self else { return }
            self.toggleMenuItem?.title = isMonitoring ? "Stop Monitoring" : "Start Monitoring"
            self.toggleMenuItem?.image = NSImage(
                systemSymbolName: isMonitoring ? "stop.circle" : "play.circle",
                accessibilityDescription: nil
            )

            // Monitoring window disabled - causes layout recursion
            // TODO: Fix and re-enable
        }
    }

    private func showMonitoringStatusWindow() {
        if monitoringStatusWindow == nil {
            let statusView = MonitoringStatusWindow()
            let hostingController = NSHostingController(rootView: statusView)

            let window = NSWindow(contentViewController: hostingController)
            window.title = "Stakhanova - Monitoring"
            window.styleMask = [.titled, .closable]
            window.level = .normal  // Changed from .floating to avoid layout issues
            window.isReleasedWhenClosed = false

            // Position in top-right corner
            if let screen = NSScreen.main {
                let screenFrame = screen.visibleFrame
                let windowSize = NSSize(width: 400, height: 500)
                let origin = NSPoint(
                    x: screenFrame.maxX - windowSize.width - 20,
                    y: screenFrame.maxY - windowSize.height - 20
                )
                window.setFrame(NSRect(origin: origin, size: windowSize), display: true)
            }

            monitoringStatusWindow = window
        }

        monitoringStatusWindow?.makeKeyAndOrderFront(nil)
    }

    private func hideMonitoringStatusWindow() {
        monitoringStatusWindow?.orderOut(nil)
    }

    @objc func toggleMonitoring() {
        AppState.shared.isMonitoring.toggle()
    }

    @objc func openCapturesFolder() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let capturesDir = appSupport.appendingPathComponent("Stakhanova", isDirectory: true)

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: capturesDir, withIntermediateDirectories: true)

        // Open in Finder
        NSWorkspace.shared.open(capturesDir)
    }

    @objc func openSettings() {
        print("openSettings called")
        if settingsWindow == nil {
            print("Creating new settings window")
            let settingsView = SettingsView()
            let hostingController = NSHostingController(rootView: settingsView)

            let window = NSWindow(contentViewController: hostingController)
            window.title = "Stakhanova"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 800, height: 600))
            window.center()

            settingsWindow = window
        }

        print("Making settings window visible")
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func requestPermissions() {
        // Request Screen Recording permission
        CGRequestScreenCaptureAccess()

        // Request Accessibility permission
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options)
    }
}
