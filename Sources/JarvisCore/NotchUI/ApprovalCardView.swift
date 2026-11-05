import SwiftUI

/// Tier 2 approval: shows exactly what will run, with Approve / Deny. Voice "yes"/"no" works too.
public struct ApprovalCardView: View {
    public var request: ApprovalRequest
    public var onDecision: (Bool) -> Void

    public init(request: ApprovalRequest, onDecision: @escaping (Bool) -> Void) {
        self.request = request
        self.onDecision = onDecision
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Approve? · \(request.toolName)", systemImage: "exclamationmark.shield")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(red: 1, green: 0.75, blue: 0.3))
            Text(request.preview)
                .font(.system(size: 12, design: request.toolName == "run_shell" ? .monospaced : .default))
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { onDecision(true) } label: {
                    Text("Approve").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .background(Capsule().fill(Color(red: 0.36, green: 0.66, blue: 1.0)))
                .foregroundStyle(.black)
                Button { onDecision(false) } label: {
                    Text("Deny").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .foregroundStyle(.white)
                Spacer()
                Text("or say “yes” / “no”").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 1, green: 0.75, blue: 0.3).opacity(0.12)))
    }
}
