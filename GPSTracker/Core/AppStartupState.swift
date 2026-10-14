import Foundation
import Combine

@MainActor
final class AppStartupState: ObservableObject {
    static let shared = AppStartupState()
    @Published var isReady = false
}
