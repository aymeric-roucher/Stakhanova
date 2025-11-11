import Foundation
import Combine

/// Single source of truth for app-wide state
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isMonitoring: Bool {
        didSet { UserDefaults.standard.set(isMonitoring, forKey: "isMonitoring") }
    }

    @Published var addClickMarker: Bool {
        didSet { UserDefaults.standard.set(addClickMarker, forKey: "addClickMarker") }
    }

    private init() {
        // Always start stopped - monitoring state should not persist across app launches
        self.isMonitoring = false

        // Restore other settings
        self.addClickMarker = UserDefaults.standard.object(forKey: "addClickMarker") != nil
            ? UserDefaults.standard.bool(forKey: "addClickMarker")
            : true
    }
}
