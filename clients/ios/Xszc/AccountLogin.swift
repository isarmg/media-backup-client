import Foundation

struct AccountLogin {
    let server: URL
    let authorizationCode: String

    struct SavedPairing {
        let credentials: AccountLogin
        let response: BootstrapResponse
    }

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

    func matches(_ pairing: SavedPairing) -> Bool {
        server.host?.lowercased() == pairing.credentials.server.host?.lowercased()
            && (server.port ?? 443) == (pairing.credentials.server.port ?? 443)
            && authorizationCode == pairing.credentials.authorizationCode
    }

    func authenticate(
        savedPairing: SavedPairing? = nil,
        validateSession: (URL, String) async throws -> Void = BackgroundUploader.validateSession,
        prepareSession: () throws -> Void = KeychainStore.verifyWritable,
        using request: (URL, String) async throws -> BootstrapResponse = BackgroundUploader.bootstrap
    ) async throws -> BootstrapResponse {
        if let pairing = savedPairing, matches(pairing) {
            guard !pairing.response.bearerToken.isEmpty else {
                throw CoordinatorFailure.message("本机缺少配对凭据，请在服务器实例详情更换授权码后重新配对")
            }
            try await validateSession(server, pairing.response.bearerToken)
            return pairing.response
        }
        try prepareSession()
        let response = try await request(server, authorizationCode)
        guard !response.bearerToken.isEmpty else { throw CoordinatorFailure.message("服务器没有返回有效配对凭据") }
        return response
    }
}
