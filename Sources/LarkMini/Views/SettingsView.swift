import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @Environment(\.larkAccent) private var accent
    @EnvironmentObject var store: Store
    @ObservedObject private var notifications = Notifications.shared
    @State private var appId = ""
    @State private var appSecret = ""
    @State private var savedNote: String?
    @State private var controlAgentId = ""
    @State private var controlHost = ""
    @State private var controlName = ""
    @State private var controlColor = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    accountSection
                    controlSection
                    Divider().overlay(SiftStyle.line)
                    notificationSection
                    appearanceSection
                    behaviourSection
                    DisclosureGroup("Lark app credentials") { credentialsSection.padding(.top, 12) }
                        .font(.system(size: 12, weight: .medium))
                    dangerSection
                }
                .padding(16)
            }
            if let error = store.errorText { ErrorBar(text: error) }
        }
        .onAppear(perform: loadCredentials)
        .task { await notifications.refresh() }
    }

    private var header: some View {
        PaneHeader(title: "Settings", subtitle: "Connections & appearance") {
            if let savedNote {
                Text(savedNote).font(.system(size: 11)).foregroundStyle(SiftStyle.green)
            }
            IconButton(symbol: "xmark", help: "Close Settings (Esc)") { store.showingSettings = false }
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Account")
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(SiftStyle.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.me?.name ?? (store.auth == .signedIn ? "Signed in to Lark" : "Not signed in"))
                        .font(.system(size: 12, weight: .medium))
                    Text(store.auth != .signedIn ? "Connect to load your chats" : store.offline ? "Offline · saved chats available" : "Lark account connected")
                        .font(.system(size: 12))
                        .foregroundStyle(SiftStyle.secondary)
                }
                Spacer()
                if store.auth == .signedIn {
                    Button("Sign out") { store.signOut() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                } else {
                    Button("Sign in") { store.signIn() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(accent)
                }
            }
        }
    }

    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("From Credentials & Basic Info in your Lark app.").font(.system(size: 12)).foregroundStyle(SiftStyle.secondary)
            Text("App ID").font(.system(size: 12))
            TextField("App ID", text: $appId)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .padding(10)
                .background(fieldBackground)
            Text("App secret").font(.system(size: 12))
            SecureField("App secret", text: $appSecret)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .padding(10)
                .background(fieldBackground)
            VStack(alignment: .leading, spacing: 12) {
                Button("Save credentials") {
                    store.saveCredentials(appId: appId.trimmingCharacters(in: .whitespaces),
                                          secret: appSecret.trimmingCharacters(in: .whitespaces))
                    savedNote = "Saved"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { savedNote = nil }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(accent)
                Link("Open the Lark console", destination: URL(string: "https://open.larksuite.com/app")!)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(SiftStyle.secondary)
            }
            Text("Save these values to connect your Lark app. Appearance and behaviour save automatically.")
                .font(.system(size: 11))
                .foregroundStyle(SiftStyle.muted)
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Appearance")
            Text("Changes save automatically.").font(.system(size: 12)).foregroundStyle(SiftStyle.secondary)
            HStack(spacing: 8) {
                ForEach(AccentPalette.names, id: \.self) { name in
                    Button {
                        store.updateSettings { $0.accent = name }
                    } label: {
                        Circle()
                            .fill(AccentPalette.color(name))
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle().strokeBorder(Color.white.opacity(store.settings.accent == name ? 0.9 : 0), lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(name.capitalized + " accent")
                    .accessibilityLabel(name.capitalized + " accent")
                    .accessibilityAddTraits(store.settings.accent == name ? .isSelected : [])
                }
                Spacer()
                Text("Accent").font(.system(size: 12)).foregroundStyle(SiftStyle.secondary)
            }
            HStack {
                Text("Width").font(.system(size: 12))
                Slider(value: Binding(
                    get: { store.settings.panelWidth },
                    set: { value in store.updateSettings { $0.panelWidth = value.rounded() } }
                ), in: 400...480)
                Text("\(Int(store.settings.panelWidth)) pt").font(.system(size: 12, design: .monospaced)).foregroundStyle(SiftStyle.secondary)
            }
            Toggle("Show message previews", isOn: Binding(
                get: { store.settings.showPreviewText },
                set: { value in store.updateSettings { $0.showPreviewText = value } }
            ))
            .font(.system(size: 11))
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var behaviourSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Behaviour")
            HStack {
                Text("Check for messages").font(.system(size: 11))
                Picker("", selection: Binding(
                    get: { store.settings.pollSeconds },
                    set: { value in store.updateSettings { $0.pollSeconds = value } }
                )) {
                    Text("3s").tag(3)
                    Text("5s").tag(5)
                    Text("10s").tag(10)
                    Text("30s").tag(30)
                }
                .labelsHidden()
                .frame(width: 70)
            }
            Toggle("Collapse when I click elsewhere", isOn: Binding(
                get: { store.settings.collapseOnOutsideClick },
                set: { value in store.updateSettings { $0.collapseOnOutsideClick = value } }
            ))
            .font(.system(size: 11))
            .toggleStyle(.switch)
            .controlSize(.small)
            Toggle("Open at login", isOn: Binding(
                get: { store.settings.launchAtLogin },
                set: { value in
                    store.updateSettings { $0.launchAtLogin = value }
                    setLaunchAtLogin(value)
                }
            ))
            .font(.system(size: 11))
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var notificationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Notifications")
            Text("Replies add a dot. An open ask or a Paseo permission request pulses the head until you see it.")
                .font(.system(size: 12)).foregroundStyle(SiftStyle.secondary)
            Toggle("macOS notifications", isOn: $notifications.enabled)
                .font(.system(size: 12)).toggleStyle(.switch).controlSize(.small)
            Toggle("Notification sound", isOn: $notifications.sound)
                .font(.system(size: 12)).toggleStyle(.switch).controlSize(.small)
                .disabled(!notifications.enabled)
            Text(notifications.enabled ? notifications.state : "Edge cues only · macOS notifications off")
                .font(.system(size: 11)).foregroundStyle(SiftStyle.secondary)
            if notifications.enabled {
                if let result = notifications.testResult {
                    Text(result).font(.system(size: 11)).foregroundStyle(SiftStyle.secondary)
                }
                if let hint = notifications.hint {
                    Text(hint).font(.system(size: 11)).foregroundStyle(SiftStyle.secondary)
                }
                Button("Open notification settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(accent)
                    .accessibilityLabel("Open notification settings")
                Button("Send test notification") {
                    NotificationCenter.default.post(name: .collapsePanel, object: nil)
                    Task {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        await notifications.test()
                    }
                }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(accent)
                    .accessibilityLabel("Send test notification")
            }
        }
    }

    private var dangerSection: some View {
        HStack {
            Button("Quit Sift") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(SiftStyle.secondary)
            Spacer()
            Text("Sift · v0.1").font(.system(size: 11)).foregroundStyle(SiftStyle.muted)
        }
    }

    private var controlSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Agents")
            Text(store.paseoAvailable ? "Paseo installed · each agent follows its own handoffs" : "Paseo CLI unavailable · check the Paseo app installation.")
                .font(.system(size: 11))
                .foregroundStyle(SiftStyle.secondary)
            ForEach(store.seats) { seat in
                SeatSettingsRow(seat: seat)
            }
            Text(store.seats.isEmpty ? "Add an agent" : "Add another agent").font(.system(size: 12, weight: .medium))
            HStack(spacing: 8) {
                TextField("Name (blank for Paseo's title)", text: $controlName)
                    .textFieldStyle(.plain).font(.system(size: 11)).padding(10).background(fieldBackground)
                FaceColorPicker(selection: $controlColor)
            }
            TextField("Paseo agent or session id", text: $controlAgentId)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .padding(10)
                .background(fieldBackground)
            TextField("Host (blank for this Mac)", text: $controlHost)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .padding(10)
                .background(fieldBackground)
            Button("Add agent") {
                let id = controlAgentId, host = controlHost, name = controlName, color = controlColor
                controlAgentId = ""; controlName = ""; controlColor = ""
                Task { await store.addSeat(agentId: id, host: host.isEmpty ? nil : host, name: name, color: color) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(accent)
            .disabled(controlAgentId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.white.opacity(0.07))
    }

    private func loadCredentials() {
        if let creds = store.currentCredentials() {
            appId = creds.appId
            appSecret = creds.appSecret
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                store.errorText = "Login item: \(error.localizedDescription)"
            }
        }
    }
}

/// One configured agent: rename, recolour, see its connection, remove it.
struct SeatSettingsRow: View {
    @EnvironmentObject var store: Store
    @ObservedObject var seat: SeatSession
    @State private var name = ""
    @State private var color = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                FaceIcon(size: 24, palette: FacePalette.named(color.isEmpty ? FacePalette.pick(for: name.isEmpty ? seat.config.title : name) : color))
                TextField(seat.config.title, text: $name)
                    .textFieldStyle(.plain).font(.system(size: 12, weight: .medium))
                    .onSubmit(save)
                FaceColorPicker(selection: $color)
                    .onChange(of: color) { save() }
                Button("Remove") { store.removeSeat(seat) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
            Text("Connection: " + seat.status + (seat.needsInput ? " · waiting for your permission" : ""))
                .font(.system(size: 11)).foregroundStyle(SiftStyle.secondary)
            Text("Asks: " + seat.asksSummary)
                .font(.system(size: 11)).foregroundStyle(SiftStyle.secondary)
            Text("Host: " + (seat.config.host.flatMap { $0.isEmpty ? nil : $0 } ?? "This Mac"))
                .font(.system(size: 11)).foregroundStyle(SiftStyle.secondary).textSelection(.enabled)
            DisclosureGroup("Session details") {
                Text("Provider: " + seat.config.provider).font(.system(size: 11))
                Text(seat.config.agentId).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }.font(.system(size: 11)).foregroundStyle(SiftStyle.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
        .onAppear { name = seat.config.name; color = seat.config.color }
        .onDisappear(perform: save)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != seat.config.name || color != seat.config.color else { return }
        seat.rename(name: trimmed, color: color)
    }
}

/// The face hues; the first dot is "automatic", a stable hue from the name.
struct FaceColorPicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach([""] + FacePalette.names.filter { $0 != "green" }, id: \.self) { name in
                Button { selection = name } label: {
                    Circle()
                        .fill(name.isEmpty ? AnyShapeStyle(SiftStyle.raised) : AnyShapeStyle(FacePalette.named(name).top))
                        .frame(width: 12, height: 12)
                        .overlay(Circle().strokeBorder(.white.opacity(selection == name ? 0.9 : 0), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .help(name.isEmpty ? "Automatic" : name.capitalized)
                .accessibilityLabel(name.isEmpty ? "Automatic colour" : name.capitalized)
            }
        }
    }
}
