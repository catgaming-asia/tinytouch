import Foundation

/// Lights the device LED (`LED_PROMPT 1`) while macOS shows a password prompt,
/// and turns it off when the prompt goes away, after a touch, or after the timeout.
@MainActor
final class PromptLedMonitor {
    static let timeoutChoices = [1, 2, 5, 10, 0] // minutes, 0 = no limit

    private unowned let model: AppModel
    private var timer: Timer?
    private var ledOn = false
    private var promptSince: Date?
    private var suppressedUntilPromptEnds = false

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
    }

    func stop() {
        timer?.invalidate()
        setLed(false)
    }

    /// Re-sends the current state after a reconnect.
    func resync() {
        model.setDeviceLed(ledOn)
    }

    func touchHandled() {
        suppressedUntilPromptEnds = true
        setLed(false)
    }

    private func evaluate() {
        guard model.promptLedEnabled, model.connection.isConnected else {
            setLed(false)
            return
        }
        let visible = SystemContext.passwordPromptVisible
        if !visible {
            promptSince = nil
            suppressedUntilPromptEnds = false
            setLed(false)
            return
        }
        let since = promptSince ?? Date()
        promptSince = since
        let limit = model.promptLedTimeoutMinutes
        let expired = limit > 0 && Date().timeIntervalSince(since) > Double(limit * 60)
        setLed(!suppressedUntilPromptEnds && !expired)
    }

    private func setLed(_ on: Bool) {
        guard on != ledOn else { return }
        ledOn = on
        model.setDeviceLed(on)
    }
}
