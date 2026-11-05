import Foundation

/// Developer test hooks: `kill -USR1 $(pgrep -x Jarvis)` behaves like hearing "Hey Jarvis"
/// (real transcription + reply), `kill -USR2 ...` shows the demo briefing card.
@MainActor
final class DebugSignals {
    private var sources: [DispatchSourceSignal] = []

    init(onWake: @escaping () -> Void, onBriefing: @escaping () -> Void, onApprovalDemo: @escaping () -> Void, demo: DemoDriver) {
        // USR1 = wake, USR2 = real briefing, INFO = a real Tier 2 request through the dispatcher.
        for (sig, action) in [(SIGUSR1, onWake), (SIGUSR2, onBriefing), (SIGINFO, onApprovalDemo)] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                JarvisLog.info("Debug signal \(sig) received")
                action()
            }
            src.resume()
            sources.append(src)
        }
    }
}
