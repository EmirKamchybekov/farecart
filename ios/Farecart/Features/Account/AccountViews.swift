import AuthenticationServices
import SwiftUI
import FarecartKit

/// Every way in, shared by onboarding and Settings: Continue with Google, Sign in with Apple,
/// "Sign up with email" (sheet) and "I already have an account" (sheet), plus the friendly
/// error line for the Apple / Google flows.
struct AccountButtons: View {
    @Environment(AccountModel.self) private var account
    @Environment(\.colorScheme) private var colorScheme
    @State private var sheet: EmailSheet?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SignInWithGoogleButton()
            SignInWithAppleButton(.signIn) { request in
                account.configure(request)
            } onCompletion: { result in
                Task { await account.complete(result) }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            .disabled(account.isBusy)
            .overlay {
                if account.isBusy && sheet == nil { ProgressView().tint(colorScheme == .dark ? .black : .white) }
            }
            Button {
                sheet = .signUp
            } label: {
                Label("Sign up with email", systemImage: "envelope.fill")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                    .foregroundStyle(.white)
                    .contentShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(account.isBusy)
            Button {
                sheet = .signIn
            } label: {
                Text("I already have an account")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(account.isBusy)
            if let message = account.errorMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(item: $sheet) { kind in
            switch kind {
            case .signUp: EmailSignUpSheet()
            case .signIn: EmailSignInSheet()
            }
        }
        #if DEBUG
        .task {
            if let kind = DebugLaunch.consumeAuthSheet() { sheet = kind }
        }
        #endif
    }
}

enum EmailSheet: String, Identifiable {
    case signUp, signIn
    var id: String { rawValue }
}

/// Name, email, password (show / hide, 8-character hint), Create account.
struct EmailSignUpSheet: View {
    @Environment(AccountModel.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var name = DebugLaunch.authPrefill.name
    @State private var email = DebugLaunch.authPrefill.email
    @State private var password = DebugLaunch.authPrefill.password
    @State private var message: String?
    @State private var isError = true
    @FocusState private var focus: Field?

    private enum Field { case name, email, password }

    private var canSubmit: Bool {
        AccountModel.looksLikeEmail(email) && password.count >= AccountModel.minimumPasswordLength && !account.isBusy
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                        .submitLabel(.next)
                        .focused($focus, equals: .name)
                        .onSubmit { focus = .email }
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .email)
                        .onSubmit { focus = .password }
                    PasswordField(title: "Password", text: $password, isNew: true)
                        .focused($focus, equals: .password)
                        .onSubmit { Task { await submit() } }
                } footer: {
                    Text("At least 8 characters.")
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if account.isBusy { ProgressView() } else { Text("Create account").fontWeight(.semibold) }
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)
                } footer: {
                    if let message {
                        Label(message, systemImage: isError ? "exclamationmark.circle.fill" : "envelope.badge")
                            .foregroundStyle(isError ? .red : .secondary)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("Sign up with email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { if name.isEmpty { focus = .name } }
            #if DEBUG
            .task {
                if DebugLaunch.authSubmit {
                    try? await Task.sleep(for: .milliseconds(800))
                    await submit()
                }
            }
            #endif
        }
        .presentationDetents([.large])
    }

    private func submit() async {
        guard !account.isBusy else { return }
        switch await account.signUpWithEmail(name: name, email: email, password: password) {
        case .signedIn: dismiss()
        case .confirmationSent(let text), .resetSent(let text): isError = false; message = text
        case .failed(let text): isError = true; message = text
        }
    }
}

/// Email, password, Sign in, Forgot password.
struct EmailSignInSheet: View {
    @Environment(AccountModel.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var email = DebugLaunch.authPrefill.email
    @State private var password = DebugLaunch.authPrefill.password
    @State private var message: String?
    @State private var isError = true
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .email)
                        .onSubmit { focus = .password }
                    PasswordField(title: "Password", text: $password, isNew: false)
                        .focused($focus, equals: .password)
                        .onSubmit { Task { await signIn() } }
                }
                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            Spacer()
                            if account.isBusy { ProgressView() } else { Text("Sign in").fontWeight(.semibold) }
                            Spacer()
                        }
                    }
                    .disabled(!AccountModel.looksLikeEmail(email) || password.isEmpty || account.isBusy)
                }
                Section {
                    Button {
                        Task { await reset() }
                    } label: {
                        Text("Forgot password?").frame(maxWidth: .infinity)
                    }
                    .disabled(account.isBusy)
                } footer: {
                    if let message {
                        Label(message, systemImage: isError ? "exclamationmark.circle.fill" : "envelope.badge")
                            .foregroundStyle(isError ? .red : .secondary)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { if email.isEmpty { focus = .email } }
            #if DEBUG
            .task {
                if DebugLaunch.authSubmit {
                    try? await Task.sleep(for: .milliseconds(800))
                    await signIn()
                }
            }
            #endif
        }
        .presentationDetents([.large])
    }

    private func signIn() async {
        guard !account.isBusy else { return }
        switch await account.signInWithEmail(email: email, password: password) {
        case .signedIn: dismiss()
        case .confirmationSent(let text), .resetSent(let text): isError = false; message = text
        case .failed(let text): isError = true; message = text
        }
    }

    private func reset() async {
        guard AccountModel.looksLikeEmail(email) else {
            isError = true
            message = String(localized: "Type your email above, then tap Forgot password.", bundle: LanguageBundle.current)
            focus = .email
            return
        }
        switch await account.sendPasswordReset(email: email) {
        case .resetSent(let text), .confirmationSent(let text): isError = false; message = text
        case .failed(let text): isError = true; message = text
        case .signedIn: break
        }
    }
}

/// Secure field with an eye button to show what was typed.
struct PasswordField: View {
    let title: LocalizedStringResource
    @Binding var text: String
    var isNew: Bool
    @State private var visible = DebugLaunch.showPassword

    var body: some View {
        HStack {
            Group {
                if visible {
                    TextField(text: $text) { Text(title) }
                } else {
                    SecureField(text: $text) { Text(title) }
                }
            }
            .textContentType(isNew ? .newPassword : .password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.go)
            Button {
                visible.toggle()
            } label: {
                Image(systemName: visible ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(visible ? Text("Hide password") : Text("Show password"))
        }
    }
}

/// Shown after a password-reset link signed the user in.
struct NewPasswordSheet: View {
    @Environment(AccountModel.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PasswordField(title: "New password", text: $password, isNew: true)
                        .onSubmit { Task { await save() } }
                } footer: {
                    Text("At least 8 characters.")
                }
                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack {
                            Spacer()
                            if account.isBusy { ProgressView() } else { Text("Save password").fontWeight(.semibold) }
                            Spacer()
                        }
                    }
                    .disabled(password.count < AccountModel.minimumPasswordLength || account.isBusy)
                } footer: {
                    if let message {
                        Label(message, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Choose a new password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { account.needsNewPassword = false; dismiss() }
                }
            }
        }
    }

    private func save() async {
        if let error = await account.setNewPassword(password) {
            message = error
        } else {
            dismiss()
        }
    }
}

/// "Signed in as …" with the provider, used by onboarding and Settings.
struct SignedInSummary: View {
    @Environment(AccountModel.self) private var account

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "person.crop.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Signed in as \(account.displayName ?? "")")
                    .font(.headline)
                if let email = account.session?.user.email, email != account.displayName {
                    Text(verbatim: email)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(providerLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var providerLine: LocalizedStringResource {
        switch account.provider {
        case .google: "Signed in with Google"
        case .email: "Signed in with email"
        case .apple, nil: "Signed in with Apple"
        }
    }
}

/// Settings → Account → Delete account. Explains what goes, then a destructive button with a
/// final confirmation dialog. Success signs out locally and pops back to Settings.
struct DeleteAccountView: View {
    @Environment(AccountModel.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Image(systemName: "person.crop.circle.badge.xmark")
                        .font(.system(size: 44))
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text("Delete your account?")
                        .font(.title2.weight(.bold))
                    if let email = account.session?.user.email {
                        Text(verbatim: email).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, Spacing.xs)
            }
            Section("What happens") {
                Label("Your account, name and email are removed from Farecart.", systemImage: "person.slash")
                Label("Your saved discount answers, language and theme are removed from our servers. They stay on this phone.", systemImage: "icloud.slash")
                Label("Visits you booked stay on this phone with their codes, but are no longer linked to an account.", systemImage: "calendar")
                Label("This can't be undone. You can make a new account later.", systemImage: "exclamationmark.triangle")
            }
            Section {
                Button(role: .destructive) {
                    confirming = true
                } label: {
                    HStack {
                        Spacer()
                        if account.isBusy { ProgressView() } else { Text("Delete account").fontWeight(.semibold) }
                        Spacer()
                    }
                }
                .disabled(account.isBusy || !account.isSignedIn)
            } footer: {
                if let message {
                    Label(message, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Delete account")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete your Farecart account permanently?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
        #if DEBUG
        .task {
            if DebugLaunch.confirmDeleteAccount {
                try? await Task.sleep(for: .seconds(1.5))
                await delete()
            }
        }
        #endif
    }

    private func delete() async {
        if let error = await account.deleteAccount() {
            message = error
        } else {
            dismiss()
        }
    }
}
