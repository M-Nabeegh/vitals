import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject var client: Client
    @State private var draftURL = ""
    @State private var draftToken = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://192.168.68.95:8321", text: $draftURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.system(size: 15, design: .monospaced))
                        .focused($focused)
                    SecureField("Token, if the agent requires one", text: $draftToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 15, design: .monospaced))
                } header: {
                    Text("Agent")
                } footer: {
                    Text("Reach the agent over Tailscale or a VPN. It is not built to face the open internet.")
                }

                Section {
                    Button("Connect") {
                        client.serverURL = draftURL.trimmingCharacters(in: .whitespaces)
                        client.token = draftToken.trimmingCharacters(in: .whitespaces)
                        focused = false
                        client.reconnect()
                    }
                    .disabled(draftURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let snapshot = client.snapshot {
                    Section("Connected to") {
                        row("Host", snapshot.host.hostname)
                        row("OS", snapshot.host.os)
                        row("Kernel", snapshot.host.kernel)
                        row("Uptime", Fmt.uptime(snapshot.host.uptime))
                        row("Viewers", "\(snapshot.agent.viewers)")
                        row("Samples this session", "\(snapshot.agent.samples)")
                        row("Times woken", "\(snapshot.agent.wakes)")
                        row("Docker", snapshot.agent.docker ? "connected" : "unavailable")
                    }
                }

                Section {
                    Text("The agent sits at zero while nobody is watching. Opening this app starts it sampling; sending the app to the background stops it again.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } header: {
                    Text("How it works")
                }
            }
            .navigationTitle("Settings")
        }
        .onAppear {
            draftURL = client.serverURL
            draftToken = client.token
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
