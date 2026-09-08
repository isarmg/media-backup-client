import SwiftUI

struct AccountScreen: View {
    @EnvironmentObject private var coordinator: BackupCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
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
                Section("服务器与账户") {
                    TextField("https://backup.example.com", text: $server)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("服务器地址").accessibilityIdentifier("account.server")
                    TextField("账户", text: $username).textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("account.username")
                    SecureField("密码", text: $password).textContentType(.password)
                        .accessibilityIdentifier("account.password")
                }.disabled(busy)
                Section {
                    Button {
                        busy = true; message = ""
                        Task {
                            defer { busy = false }
                            do { try await coordinator.login(server: server, username: username, password: password); dismiss() }
                            catch { message = error.localizedDescription }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() }
                            Text(busy ? "正在登录…" : "登录").fontWeight(.semibold)
                            Spacer()
                        }.padding(.vertical, 6)
                    }
                    .disabled(busy || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                    .accessibilityIdentifier("account.submit")
                    if !message.isEmpty { Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                } footer: { Text("请使用服务器中的备份账户。只有验证成功后才会保存新的登录信息。") }
            }
            .navigationTitle("登录账户").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
            .onAppear { server = coordinator.serverURL; username = coordinator.username; password = coordinator.password }
        }
    }
}
