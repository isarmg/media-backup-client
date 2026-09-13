import Foundation

struct AccountLogin {
    let server: URL
    let authorizationCode: String

    init(server: String, authorizationCode: String) throws {
        let address = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address), url.scheme == "https", url.host != nil,
            url.user == nil, url.password == nil, url.path.isEmpty || url.path == "/",
            url.query == nil, url.fragment == nil else {
            throw CoordinatorFailure.message("请输入 HTTPS 服务器根地址，例如 https://backup.example.com")
        }
        guard !code.isEmpty else { throw CoordinatorFailure.message("请输入实例授权码") }
        self.server = url; self.authorizationCode = code
    }

    func authenticate(using request: (URL, String) async throws -> BootstrapResponse = BackgroundUploader.bootstrap) async throws -> BootstrapResponse {
        let response = try await request(server, authorizationCode)
        guard !response.bearerToken.isEmpty else { throw CoordinatorFailure.message("服务器没有返回有效配对凭据") }
        return response
    }
}
