import SwiftUI
import FarecartKit

/// Settings → "I work at a pantry": type the 6-character staff code. On success the store keeps
/// the session and `StaffEntryView` shows the staff screen.
struct StaffLoginView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var code = ""
    @State private var isBusy = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    private var normalized: String { StaffSession.normalize(code: code) }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.l) {
                VStack(spacing: Spacing.s) {
                    Image(systemName: "person.badge.key.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text("Enter your pantry's staff code")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("Ask your pantry coordinator for the 6-character code. It lets you post today's stock, open visit slots and check people in.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, Spacing.l)

                VStack(spacing: Spacing.s) {
                    TextField("Code", text: $code)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospaced()
                        .multilineTextAlignment(.center)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .submitLabel(.go)
                        .focused($focused)
                        .onSubmit { Task { await login() } }
                        .onChange(of: code) { _, value in
                            let cleaned = StaffSession.normalize(code: value)
                            if cleaned != value { code = String(cleaned.prefix(8)) }
                        }
                        .padding(.vertical, Spacing.s)
                        .frame(maxWidth: .infinity)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                        .accessibilityLabel("Staff code")
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Button {
                    Task { await login() }
                } label: {
                    if isBusy {
                        ProgressView().tint(.white).frame(maxWidth: .infinity, minHeight: 32).padding(.vertical, 8)
                    } else {
                        BigButtonLabel(title: "Continue", systemImage: "arrow.right")
                    }
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .disabled(normalized.count < 6 || isBusy)

                Text("Only people with a code can change a pantry's listing. Nothing you post is tied to your name.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Spacing.m)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Pantry staff")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
    }

    private func login() async {
        guard normalized.count >= 6, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await environment.pantry.staffLogin(code: normalized)
        } catch {
            errorMessage = PantryError.wrap(error).userMessage
        }
    }
}

/// Shows the staff screen when a session exists, the code entry otherwise.
struct StaffEntryView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Group {
            if let session = environment.pantry.staffSession {
                StaffHomeView(session: session)
            } else {
                StaffLoginView()
            }
        }
        #if DEBUG
        .task {
            // `-farecart-staff-code A7GBQZ`: sign in to staff mode on launch (screenshots).
            let arguments = ProcessInfo.processInfo.arguments
            guard environment.pantry.staffSession == nil,
                  let index = arguments.firstIndex(of: "-farecart-staff-code"), index + 1 < arguments.count else { return }
            _ = try? await environment.pantry.staffLogin(code: arguments[index + 1])
        }
        #endif
    }
}

#Preview {
    NavigationStack { StaffLoginView() }
        .environment(AppEnvironment.preview())
}
