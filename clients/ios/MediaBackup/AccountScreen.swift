import SwiftUI

struct AccountScreen: View {
    @EnvironmentObject private var coordinator: BackupCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var authorizationCode = ""
    @State private var authorizationCodeVisible = false
    @State private var busy = false
    @State private var message = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("连接你的媒体库", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.title2.bold()).padding(.vertical, 12)
                    Text("登录后即可备份所选照片、浏览云端媒体。")
                        .foregroundStyle(.secondary)
                }
                Section("服务器与实例") {
                    TextField("https://backup.example.com", text: $server)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("服务器地址").accessibilityIdentifier("account.server")
                    HStack {
                        Group {
                            if authorizationCodeVisible {
                                TextField("实例授权码", text: $authorizationCode)
                            } else {
                                SecureField("实例授权码", text: $authorizationCode)
                            }
                        }
                        .keyboardType(.asciiCapable).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("pairing.authorization-code")
                        Button(authorizationCodeVisible ? "隐藏授权码" : "显示授权码") {
                            authorizationCodeVisible.toggle()
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("pairing.authorization-code-visibility")
                    }
                }.disabled(busy)
                Section {
                    Button {
                        busy = true; message = ""
                        Task {
                            defer { busy = false }
                            do { try await coordinator.login(server: server, authorizationCode: authorizationCode); dismiss() }
                            catch { message = error.localizedDescription }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() }
                            Text(busy ? "正在配对…" : "配对").fontWeight(.semibold)
                            Spacer()
                        }.padding(.vertical, 6)
                    }
                    .disabled(busy || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("account.submit")
                    if !message.isEmpty { Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                } footer: { Text("请使用服务器实例详情中的授权码。服务端更换授权码后必须重新配对。") }
            }
            .navigationTitle("配对实例").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
            .onAppear { server = coordinator.serverURL; authorizationCode = coordinator.authorizationCode }
        }
    }
}
