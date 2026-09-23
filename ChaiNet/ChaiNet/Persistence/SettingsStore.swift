import Foundation
import Observation
import ChaiNetCore

/// Observable wrapper around `AppSettings`, persisted as JSON in UserDefaults.
@MainActor
@Observable
final class SettingsStore {
    private let defaults: UserDefaults
    private let key = "chainet.settings.v1"

    var settings: AppSettings {
        didSet { persist() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: key) }
    }

    /// Built-in + user servers.
    var allServers: [ServerDescriptor] { ServerDescriptor.builtIn + settings.customServers }

    var fixedServer: ServerDescriptor? {
        guard settings.serverSelection == .manual, let id = settings.manualServerID else { return nil }
        return allServers.first { $0.id == id }
    }

    func reset() { settings = AppSettings() }
}
