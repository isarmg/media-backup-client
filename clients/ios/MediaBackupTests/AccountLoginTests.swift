import XCTest
@testable import MediaBackup

final class AccountLoginTests: XCTestCase {
    func testRejectsInvalidOriginAndMissingCredentials() {
        for address in ["http://backup.example.com", "https://user:secret@backup.example.com", "https://backup.example.com/admin/", "https://backup.example.com/?token=x"] {
            XCTAssertThrowsError(try AccountLogin(server: address, username: "user", password: "secret"))
        }
        XCTAssertThrowsError(try AccountLogin(server: "https://backup.example.com", username: "  ", password: "secret"))
        XCTAssertThrowsError(try AccountLogin(server: "https://backup.example.com", username: "user", password: ""))
    }
    func testExplicitLoginValidatesCredentialsWithoutTrimmingPassword() async throws {
        let login = try AccountLogin(server: " https://backup.example.com/ ", username: " user ", password: " secret ")
        let expected = BootstrapResponse(bearerToken: "test-token", accountId: UUID(), deviceId: UUID())
        let response = try await login.authenticate { url, username, password in
            XCTAssertEqual(url.absoluteString, "https://backup.example.com/")
            XCTAssertEqual(username, "user")
            XCTAssertEqual(password, " secret ")
            return expected
        }
        XCTAssertEqual(response.bearerToken, expected.bearerToken)
        XCTAssertEqual(response.accountId, expected.accountId)
    }
    func testFailureAndEmptyTokenCannotReportSuccessfulLogin() async throws {
        let login = try AccountLogin(server: "https://backup.example.com", username: "user", password: "wrong")
        do {
            _ = try await login.authenticate { _, _, _ in throw CoordinatorFailure.message("账户或密码不正确") }
            XCTFail("Rejected credentials must not produce a session")
        } catch { XCTAssertEqual(error.localizedDescription, "账户或密码不正确") }
        do {
            _ = try await login.authenticate { _, _, _ in BootstrapResponse(bearerToken: "", accountId: UUID(), deviceId: UUID()) }
            XCTFail("Missing bearer token must not produce a session")
        } catch { XCTAssertTrue(error.localizedDescription.contains("有效登录凭据")) }
    }
}
