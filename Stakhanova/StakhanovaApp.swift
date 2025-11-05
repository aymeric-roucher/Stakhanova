import SwiftUI

@main
struct StakhanovaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem?
    var eventMonitor: EventMonitor?
    var captureService: CaptureService?

    var startMenuItem: NSMenuItem?
    var stopMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "camera.circle", accessibilityDescription: "Stakhanova")
        }

        setupMenu()

        // Initialize services
        captureService = CaptureService()
        eventMonitor = EventMonitor(captureService: captureService!)

        // Request permissions on first launch
        requestPermissions()
    }

    func setupMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        startMenuItem = NSMenuItem(title: "Start Monitoring", action: #selector(startMonitoring), keyEquivalent: "s")
        startMenuItem?.target = self

        stopMenuItem = NSMenuItem(title: "Stop Monitoring", action: #selector(stopMonitoring), keyEquivalent: "t")
        stopMenuItem?.target = self

        menu.addItem(startMenuItem!)
        menu.addItem(stopMenuItem!)
        menu.addItem(NSMenuItem.separator())

        let openFolderItem = NSMenuItem(title: "Open Captures Folder", action: #selector(openCapturesFolder), keyEquivalent: "o")
        openFolderItem.target = self
        menu.addItem(openFolderItem)

        let analyzeItem = NSMenuItem(title: "Analyze Screenshots", action: #selector(analyzeScreenshots), keyEquivalent: "a")
        analyzeItem.target = self
        menu.addItem(analyzeItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
        menu.delegate = self
        updateMenuItems()
    }

    @objc func startMonitoring() {
        captureService?.startSession()
        eventMonitor?.start()
        updateMenuItems()
        print("Started monitoring clicks")
    }

    @objc func stopMonitoring() {
        eventMonitor?.stop()
        captureService?.endSession()
        updateMenuItems()
        print("Stopped monitoring clicks")
    }

    func updateMenuItems() {
        let isRunning = eventMonitor?.isRunning ?? false
        startMenuItem?.isEnabled = !isRunning
        stopMenuItem?.isEnabled = isRunning
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenuItems()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let isRunning = eventMonitor?.isRunning ?? false
        print("validateMenuItem called - isRunning: \(isRunning)")

        if menuItem == startMenuItem {
            print("Validating Start - should be enabled: \(!isRunning)")
            return !isRunning
        }

        if menuItem == stopMenuItem {
            print("Validating Stop - should be enabled: \(isRunning)")
            return isRunning
        }

        return true
    }

    @objc func openCapturesFolder() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let capturesDir = appSupport.appendingPathComponent("Stakhanova", isDirectory: true)

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: capturesDir, withIntermediateDirectories: true)

        // Open in Finder
        NSWorkspace.shared.open(capturesDir)
    }

    @objc func analyzeScreenshots() {
        // TODO: Trigger LLM analysis
        print("Analyzing screenshots...")
    }

    @objc func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func requestPermissions() {
        // Request Screen Recording permission
        CGRequestScreenCaptureAccess()

        // Request Accessibility permission
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options)
    }
}
