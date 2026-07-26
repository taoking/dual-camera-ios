import SwiftUI

struct CameraStatusView: View {
    let notice: CameraNotice?
    let state: CameraState

    var body: some View {
        if let notice {
            status(notice.message, symbol: notice.kind.symbolName, tint: tint(for: notice.kind))
        } else if let message = state.message {
            status(message, symbol: state.symbolName, tint: .white)
        }
    }

    private func status(_ message: String, symbol: String, tint: Color) -> some View {
        Label(message, systemImage: symbol)
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
}
