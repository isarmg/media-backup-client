import XCTest
@testable import MediaBackup

final class AccountLoginTests: XCTestCase {
    @MainActor
    func testBackupPreferencesAreSavedOnlyAfterConfirmation() {
        let preferences = MobileContractV02.preferences
        let keys = ["auto_backup", "wifi_only", "charging_only", "backup_photos", "backup_videos", "selected_album_ids"]
        let previous = keys.map { ($0, preferences.object(forKey: $0)) }
        defer {
            for (key, value) in previous {
                if let value { preferences.set(value, forKey: key) }
                else { preferences.removeObject(forKey: key) }
            }
        }
        let coordinator = BackupCoordinator()
        coordinator.autoBackup = false
        coordinator.serverURL = ""
        coordinator.authorizationCode = ""
        let album = "test-album-\(UUID().uuidString)"
        coordinator.setAlbum(album, enabled: true)
        XCTAssertFalse((preferences.stringArray(forKey: "selected_album_ids") ?? []).contains(album))

        coordinator.saveSettings()
        XCTAssertEqual(coordinator.status, "备份偏好已保存")
        XCTAssertTrue((preferences.stringArray(forKey: "selected_album_ids") ?? []).contains(album))
    }

    func testRejectsInvalidOriginAndMissingCredentials() {
        for address in ["http://backup.example.com", "https://user:secret@backup.example.com", "https://backup.example.com/admin/", "https://backup.example.com/?token=x"] {
            XCTAssertThrowsError(try AccountLogin(server: address, authorizationCode: "instance-code"))
        }
        XCTAssertThrowsError(try AccountLogin(server: "https://backup.example.com", authorizationCode: "  "))
    }
    func testExplicitPairingValidatesAndTrimsAuthorizationCode() async throws {
        let login = try AccountLogin(server: " https://backup.example.com/ ", authorizationCode: " instance-code ")
        let expected = BootstrapResponse(bearerToken: "test-token", accountId: UUID(), deviceId: UUID())
        let response = try await login.authenticate { url, authorizationCode in
            XCTAssertEqual(url.absoluteString, "https://backup.example.com/")
            XCTAssertEqual(authorizationCode, "instance-code")
            return expected
        }
        XCTAssertEqual(response.bearerToken, expected.bearerToken)
        XCTAssertEqual(response.accountId, expected.accountId)
    }
    func testFailureAndEmptyTokenCannotReportSuccessfulLogin() async throws {
        let login = try AccountLogin(server: "https://backup.example.com", authorizationCode: "wrong-code")
        do {
            _ = try await login.authenticate { _, _ in throw CoordinatorFailure.message("授权码无效") }
            XCTFail("Rejected credentials must not produce a session")
        } catch { XCTAssertEqual(error.localizedDescription, "授权码无效") }
        do {
            _ = try await login.authenticate { _, _ in BootstrapResponse(bearerToken: "", accountId: UUID(), deviceId: UUID()) }
            XCTFail("Missing bearer token must not produce a session")
        } catch { XCTAssertTrue(error.localizedDescription.contains("有效配对凭据")) }
    }
}
