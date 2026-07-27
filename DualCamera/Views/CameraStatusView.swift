import SwiftUI

struct CameraStatusView: View {
    let notice: CameraNotice?
    let state: CameraState
    let onAction: (CameraNoticeAction, CameraNotice?) -> Void

    var body: some View {
        if let notice {
            status(
                notice.message,
                symbol: notice.kind.symbolName,
                tint: tint(for: notice.kind),
                action: notice.action,
                notice: notice
            )
        } else if let message = state.message {
            status(
                message,
                symbol: state.symbolName,
                tint: .white,
                action: state.recoveryAction,
                notice: nil
            )
        }
    }

    private func status(
        _ message: String,
        symbol: String,
        tint: Color,
        action: CameraNoticeAction,
        notice: CameraNotice?
    ) -> some View {
        VStack(spacing: 8) {
            Label(message, systemImage: symbol)
                .accessibilityIdentifier("camera-status")
            if action != .none {
                Button(actionTitle(for: action)) { onAction(action, notice) }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.18), in: Capsule())
                    .accessibilityIdentifier("camera-status-action")
            }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(tint)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 14))
    }

    private func tint(for kind: CameraNoticeKind) -> Color {
        switch kind {
        case .info: .white
        case .success: .green
        case .error: .red
        }
    }

    private func actionTitle(for action: CameraNoticeAction) -> String {
        switch action {
        case .none: ""
        case .openAppSettings: "打开设置"
        case .retrySession: "重试相机"
        case .retryMediaSaves: "重试保存"
        }
    }
}
