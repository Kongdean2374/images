import Foundation

struct WorkoutOptions: Codable {
    var autoPause: Bool
    var gpsTargetPace: Double
    var gpsAutoLapDistance: Double
    var assistedTracking: Bool
    var backgroundLocation: Bool
    var batterySaver: Bool
    var keepScreenAwake: Bool
    var voiceCues: Bool
    var hapticCues: Bool
    var announceIntervalRaw: Double
    var announceDistance: Bool
    var announcePace: Bool
    var announceDuration: Bool
    var announcePacerDelta: Bool
}

extension AppSettings {
    func workoutOptions(for id: String) -> WorkoutOptions {
        let baseline = WorkoutOptions(autoPause: autoPause,
                                      gpsTargetPace: gpsTargetPace,
                                      gpsAutoLapDistance: gpsAutoLapDistance,
                                      assistedTracking: assistedTracking,
                                      backgroundLocation: backgroundLocation,
                                      batterySaver: batterySaver,
                                      keepScreenAwake: keepScreenAwake,
                                      voiceCues: voiceCues,
                                      hapticCues: hapticCues,
                                      announceIntervalRaw: announceIntervalRaw,
                                      announceDistance: announceDistance,
                                      announcePace: announcePace,
                                      announceDuration: announceDuration,
                                      announcePacerDelta: announcePacerDelta)
        guard let data = try? JSONEncoder().encode(baseline),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return baseline }
        let overrides = (try? JSONSerialization.jsonObject(with: workoutOverrides)) as? [String: [String: Any]] ?? [:]
        object.merge(overrides[id] ?? [:]) { _, new in new }
        guard let merged = try? JSONSerialization.data(withJSONObject: object),
              let result = try? JSONDecoder().decode(WorkoutOptions.self, from: merged) else { return baseline }
        return result
    }

    func updateWorkoutOptions(for id: String, _ change: (inout WorkoutOptions) -> Void) {
        let before = workoutOptions(for: id)
        var after = before
        change(&after)
        guard let oldData = try? JSONEncoder().encode(before),
              let newData = try? JSONEncoder().encode(after),
              let old = (try? JSONSerialization.jsonObject(with: oldData)) as? [String: Any],
              let new = (try? JSONSerialization.jsonObject(with: newData)) as? [String: Any] else { return }
        var all = (try? JSONSerialization.jsonObject(with: workoutOverrides)) as? [String: [String: Any]] ?? [:]
        var patch = all[id] ?? [:]
        for (key, value) in new where !NSDictionary(dictionary: [key: value]).isEqual(to: [key: old[key] as Any]) {
            patch[key] = value
        }
        all[id] = patch
        if let data = try? JSONSerialization.data(withJSONObject: all) { workoutOverrides = data }
    }

    func resetWorkoutOptions(for id: String) {
        var all = (try? JSONSerialization.jsonObject(with: workoutOverrides)) as? [String: [String: Any]] ?? [:]
        all.removeValue(forKey: id)
        if let data = try? JSONSerialization.data(withJSONObject: all) { workoutOverrides = data }
    }
}
