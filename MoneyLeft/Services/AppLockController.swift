import Foundation
import LocalAuthentication

/// Face ID / Touch ID / 密碼鎖。純本機驗證。
@MainActor
final class AppLockController: ObservableObject {
    @Published private(set) var isLocked: Bool = AppSettings.appLockEnabled
    @Published private(set) var failureMessage: String?
    private var isAuthenticating = false

    static var biometryAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    func lockIfNeeded() {
        if AppSettings.appLockEnabled { isLocked = true }
    }

    func unlockIfDisabled() {
        if !AppSettings.appLockEnabled { isLocked = false }
    }

    func authenticate() {
        guard AppSettings.appLockEnabled, isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        failureMessage = nil

        let context = LAContext()
        context.localizedCancelTitle = "取消"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // 裝置沒有設密碼 → 不要把使用者鎖在外面
            AppSettings.appLockEnabled = false
            isLocked = false
            isAuthenticating = false
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "解鎖 MoneyLeft") { [weak self] success, evaluateError in
            Task { @MainActor in
                guard let self else { return }
                self.isAuthenticating = false
                if success {
                    self.isLocked = false
                    self.failureMessage = nil
                } else {
                    self.failureMessage = (evaluateError as? LAError)?.code == .userCancel
                        ? nil
                        : "驗證失敗，請再試一次。"
                }
            }
        }
    }
}
