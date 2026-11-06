import SwiftUI
import AppKit

struct SignInView: View {
    @Environment(\.larkAccent) private var accent
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 20)
            FaceIcon(size: 60)

            Text("Sift")
                .font(.system(size: 24, weight: .semibold))
            Text("Your chats, floating where you work.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if let code = store.deviceCode {
                VStack(spacing: 6) {
                    Text("Enter this code in Lark")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(code.userCode)
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Open the sign-in page") {
                        NSWorkspace.shared.open(code.verifyURL)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(accent)
                    ProgressView().controlSize(.mini)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
            } else if store.auth == .signingIn {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    store.signIn()
                } label: {
                    Text("Sign in with Lark")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(accent.opacity(0.9)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }

            if let error = store.errorText {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            Spacer(minLength: 10)
            HStack(spacing: 14) {
                Button("Settings") { store.showingSettings = true }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
    }
}
