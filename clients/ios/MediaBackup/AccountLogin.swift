import Foundation

struct AccountLogin {
    let server: URL
    let username: String
    let password: String

    init(server: String, username: String, password: String) throws {
        let address = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address), url.scheme == "https", url.host != nil,
            url.user == nil, url.password == nil, url.path.isEmpty || url.path == "/",
            url.query == nil, url.fragment == nil else {
            throw CoordinatorFailure.message("请输入 HTTPS 服务器根地址，例如 https://backup.example.com")
        }
        guard !user.isEmpty, !password.isEmpty else { throw CoordinatorFailure.message("请输入账户和密码") }
        self.server = url; self.username = user; self.password = password
    }

    func authenticate(using request: (URL, String, String) async throws -> BootstrapResponse = BackgroundUploader.bootstrap) async throws -> BootstrapResponse {
        let response = try await request(server, username, password)
        guard !response.bearerToken.isEmpty else { throw CoordinatorFailure.message("服务器没有返回有效登录凭据") }
        return response
    }
}
