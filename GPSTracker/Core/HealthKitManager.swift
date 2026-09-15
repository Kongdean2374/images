import Foundation
import HealthKit
import CoreLocation

/// 寫入健康 App 用的值型別快照（在主執行緒建立，之後可安全跨執行緒使用）。
struct WorkoutSnapshot {
    let type: WorkoutType
    let start: Date
    let end: Date
    let distance: Double?
    let calories: Double?
    let floorsAscended: Int?
    let locations: [CLLocation]

    @MainActor
    init(session: WorkoutSession) {
        type = session.type
        start = session.startDate
        end = session.endDate
        distance = session.totalDistance
        calories = session.calories
        floorsAscended = session.floorsAscended
        locations = session.sortedPoints.map { point in
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: point.latitude,
                                                          longitude: point.longitude),
                       altitude: point.altitude,
                       horizontalAccuracy: 5,
                       verticalAccuracy: 5,
                       course: -1,
                       speed: point.speed,
                       timestamp: point.timestamp)
        }
    }
}

/// 健康 App 整合。
///
/// 注意：HealthKit 需要 `com.apple.developer.healthkit` entitlement。
/// 用免費 Apple ID 自簽的版本拿不到這個能力，此時所有呼叫都會安全失敗，
/// App 其他功能完全不受影響（不會閃退），並在設定頁顯示「此簽名未啟用」。
final class HealthKitManager: ObservableObject {
    static let shared = HealthKitManager()

    enum Availability: Equatable {
        case unknown
        case unavailableOnDevice      // 例如 iPad 沒有健康 App
        case notEntitled              // 簽名沒有 HealthKit 能力
        case denied
        case ready

        var displayName: String {
            switch self {
            case .unknown: return "尚未檢查"
            case .unavailableOnDevice: return "此裝置不支援健康資料"
            case .notEntitled: return "此簽名未啟用健康整合"
            case .denied: return "已拒絕健康權限"
            case .ready: return "已連結健康 App"
            }
        }
    }

    @Published private(set) var availability: Availability = .unknown
    @Published private(set) var lastError: String?
    @Published private(set) var lastSyncDate: Date?

    private let store = HKHealthStore()

    var isReady: Bool { availability == .ready }

    // MARK: 型別

    private var shareTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [HKObjectType.workoutType()]
        types.insert(HKQuantityType(.distanceWalkingRunning))
        types.insert(HKQuantityType(.activeEnergyBurned))
        types.insert(HKQuantityType(.flightsClimbed))
        types.insert(HKSeriesType.workoutRoute())
        return types
    }

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.workoutType()]
        types.insert(HKQuantityType(.stepCount))
        types.insert(HKQuantityType(.distanceWalkingRunning))
        types.insert(HKQuantityType(.flightsClimbed))
        types.insert(HKQuantityType(.activeEnergyBurned))
        types.insert(HKQuantityType(.bodyMass))
        types.insert(HKQuantityType(.height))
        types.insert(HKQuantityType(.heartRate))
        return types
    }

    // MARK: 權限

    func refreshAvailability() {
        guard HKHealthStore.isHealthDataAvailable() else {
            update { self.availability = .unavailableOnDevice }
            return
        }
        let status = store.authorizationStatus(for: HKObjectType.workoutType())
        switch status {
        case .sharingAuthorized:
            update { self.availability = .ready }
        case .sharingDenied:
            update { self.availability = .denied }
        default:
            if availability != .notEntitled {
                update { self.availability = .unknown }
            }
        }
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else {
            update { self.availability = .unavailableOnDevice }
            return false
        }
        do {
            try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
            let status = store.authorizationStatus(for: HKObjectType.workoutType())
            update {
                self.availability = (status == .sharingDenied) ? .denied : .ready
                self.lastError = nil
            }
            return status != .sharingDenied
        } catch {
            // 缺 entitlement 時會走到這裡，安全降級而不是閃退
            update {
                self.availability = .notEntitled
                self.lastError = error.localizedDescription
            }
            return false
        }
    }

    // MARK: 寫入

    /// 把一次運動寫成健康 App 的「體能訓練」，GPS 場次連軌跡一起寫。
    ///
    /// 刻意不寫入 stepCount：iPhone 本身就在自動計步，重複寫入會讓
    /// 健康 App 的步數膨脹。
    ///
    /// 傳入的是值型別快照，SwiftData 物件只在主執行緒被讀取過一次。
    @discardableResult
    func save(_ snapshot: WorkoutSnapshot) async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        guard availability == .ready else { return false }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = Self.activityType(for: snapshot.type)
        configuration.locationType = snapshot.type.requiresLocation ? .outdoor : .indoor

        let start = snapshot.start
        let end = max(snapshot.end, snapshot.start.addingTimeInterval(1))

        do {
            let builder = HKWorkoutBuilder(healthStore: store,
                                           configuration: configuration,
                                           device: .local())
            try await builder.beginCollection(at: start)

            var samples: [HKSample] = []
            if let distance = snapshot.distance, distance > 0 {
                samples.append(HKQuantitySample(type: HKQuantityType(.distanceWalkingRunning),
                                                quantity: HKQuantity(unit: .meter(), doubleValue: distance),
                                                start: start,
                                                end: end))
            }
            if let calories = snapshot.calories, calories > 0 {
                samples.append(HKQuantitySample(type: HKQuantityType(.activeEnergyBurned),
                                                quantity: HKQuantity(unit: .kilocalorie(), doubleValue: calories),
                                                start: start,
                                                end: end))
            }
            if let floors = snapshot.floorsAscended, floors > 0 {
                samples.append(HKQuantitySample(type: HKQuantityType(.flightsClimbed),
                                                quantity: HKQuantity(unit: .count(), doubleValue: Double(floors)),
                                                start: start,
                                                end: end))
            }
            if !samples.isEmpty {
                try await builder.addSamples(samples)
            }

            try await builder.endCollection(at: end)
            guard let workout = try await builder.finishWorkout() else {
                update { self.lastError = "健康 App 未建立紀錄" }
                return false
            }

            if snapshot.locations.count > 1 {
                let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
                try await routeBuilder.insertRouteData(snapshot.locations)
                _ = try await routeBuilder.finishRoute(with: workout, metadata: nil)
            }

            update {
                self.lastSyncDate = Date()
                self.lastError = nil
            }
            return true
        } catch {
            update { self.lastError = error.localizedDescription }
            return false
        }
    }

    // MARK: 讀取

    /// 讀取最近一次體重，用來讓熱量估算更準
    func latestBodyMass() async -> Double? {
        await latestQuantity(HKQuantityType(.bodyMass), unit: .gramUnit(with: .kilo))
    }

    func latestHeight() async -> Double? {
        await latestQuantity(HKQuantityType(.height), unit: .meter())
    }

    /// 今日步數（由系統與其他來源彙整）
    func todaySteps() async -> Int? {
        let start = Calendar.current.startOfDay(for: Date())
        guard let sum = await sumQuantity(HKQuantityType(.stepCount),
                                          unit: .count(),
                                          from: start,
                                          to: Date()) else { return nil }
        return Int(sum)
    }

    /// 期間平均心率（只讀取其他來源已寫入的資料，不連任何裝置）
    func averageHeartRate(from start: Date, to end: Date) async -> Double? {
        guard HKHealthStore.isHealthDataAvailable(), availability == .ready else { return nil }
        let type = HKQuantityType(.heartRate)
        let unit = HKUnit.count().unitDivided(by: .minute())
        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let query = HKStatisticsQuery(quantityType: type,
                                          quantitySamplePredicate: predicate,
                                          options: .discreteAverage) { _, statistics, _ in
                continuation.resume(returning: statistics?.averageQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    private func latestQuantity(_ type: HKQuantityType, unit: HKUnit) async -> Double? {
        guard HKHealthStore.isHealthDataAvailable(), availability == .ready else { return nil }
        return await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(sampleType: type,
                                      predicate: nil,
                                      limit: 1,
                                      sortDescriptors: [sort]) { _, samples, _ in
                let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }

    private func sumQuantity(_ type: HKQuantityType, unit: HKUnit, from start: Date, to end: Date) async -> Double? {
        guard HKHealthStore.isHealthDataAvailable(), availability == .ready else { return nil }
        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let query = HKStatisticsQuery(quantityType: type,
                                          quantitySamplePredicate: predicate,
                                          options: .cumulativeSum) { _, statistics, _ in
                continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    // MARK: 工具

    private func update(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    static func activityType(for type: WorkoutType) -> HKWorkoutActivityType {
        switch type {
        case .gpsRun, .run: return .running
        case .treadmill: return .running
        case .walk: return .walking
        case .gpsHike: return .hiking
        case .lapCounter: return .running
        case .indoorInterval: return .highIntensityIntervalTraining
        case .indoorReps: return .functionalStrengthTraining
        case .manualEntry: return .other
        }
    }
}
