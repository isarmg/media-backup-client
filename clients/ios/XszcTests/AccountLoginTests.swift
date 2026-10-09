import XCTest
@testable import Xszc

final class AccountLoginTests: XCTestCase {
    func testPairingCredentialsCanBeSavedAndReloaded() throws {
        let key = "pairing-test-\(UUID().uuidString)"
        defer { KeychainStore.delete(key) }
        try KeychainStore.save("first-test-token", for: key)
        XCTAssertEqual(KeychainStore.load(key), "first-test-token")
        try KeychainStore.save("updated-test-token", for: key)
        XCTAssertEqual(KeychainStore.load(key), "updated-test-token")
    }

    func testMatchingSavedPairingValidatesTokenWithoutConsumingCodeAgain() async throws {
        let previous = try AccountLogin(server: "https://backup.example.com", authorizationCode: "instance-code")
        let login = try AccountLogin(server: "https://BACKUP.example.com:443/", authorizationCode: " instance-code ")
        let expected = BootstrapResponse(bearerToken: "saved-token", accountId: UUID(), deviceId: UUID())
        var validated = false
        let response = try await login.authenticate(
            savedPairing: .init(credentials: previous, response: expected),
            validateSession: { _, token in
                XCTAssertEqual(token, expected.bearerToken)
                validated = true
            }, using: { _, _ in
                XCTFail("Already paired credentials must not call bootstrap again")
                return expected
            })
        XCTAssertTrue(validated)
        XCTAssertEqual(response.deviceId, expected.deviceId)
    }

    func testUnwritableCredentialsPreventServerPairing() async throws {
        let login = try AccountLogin(server: "https://backup.example.com", authorizationCode: "instance-code")
        do {
            _ = try await login.authenticate(
                prepareSession: { throw CoordinatorFailure.message("无法保存配对凭据") },
                using: { _, _ in
                    XCTFail("Storage failure must stop pairing before the server consumes the code")
                    return BootstrapResponse(bearerToken: "test-token", accountId: UUID(), deviceId: UUID())
                })
            XCTFail("Unwritable credentials must not report successful pairing")
        } catch { XCTAssertEqual(error.localizedDescription, "无法保存配对凭据") }
    }

    func testExpiredSavedTokenDoesNotRetryConsumedCode() async throws {
        let login = try AccountLogin(server: "https://backup.example.com", authorizationCode: "instance-code")
        let saved = AccountLogin.SavedPairing(credentials: login,
            response: BootstrapResponse(bearerToken: "expired-token", accountId: UUID(), deviceId: UUID()))
        do {
            _ = try await login.authenticate(savedPairing: saved,
                validateSession: { _, _ in throw CoordinatorFailure.message("凭据已失效") },
                using: { _, _ in
                    XCTFail("An expired token requires a new code, not another bootstrap")
                    return saved.response
                })
            XCTFail("Expired credentials must not report successful pairing")
        } catch { XCTAssertEqual(error.localizedDescription, "凭据已失效") }
    }

    func testChangedServerOrCodeRequiresNewBootstrap() async throws {
        let previous = try AccountLogin(server: "https://backup.example.com", authorizationCode: "old-code")
        let saved = AccountLogin.SavedPairing(credentials: previous,
            response: BootstrapResponse(bearerToken: "old-token", accountId: UUID(), deviceId: UUID()))
        for (server, code) in [("https://backup.example.com", "new-code"), ("https://other.example.com", "old-code"), ("https://backup.example.com:8443", "old-code")] {
            let login = try AccountLogin(server: server, authorizationCode: code)
            var bootstrapped = false
            _ = try await login.authenticate(savedPairing: saved,
                validateSession: { _, _ in XCTFail("Credentials from another instance cannot be reused") },
                using: { _, actualCode in
                    XCTAssertEqual(actualCode, code)
                    bootstrapped = true
                    return BootstrapResponse(bearerToken: "new-token", accountId: UUID(), deviceId: UUID())
                })
            XCTAssertTrue(bootstrapped)
        }
    }

    @MainActor
    func testBackupPreferencesTakeEffectImmediately() {
        let preferences = MobileContractV1.preferences
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
        XCTAssertTrue((preferences.stringArray(forKey: "selected_album_ids") ?? []).contains(album))
        coordinator.wifiOnly.toggle()
        coordinator.chargingOnly.toggle()
        coordinator.backupPhotos.toggle()
        coordinator.backupVideos.toggle()
        let restored = BackupCoordinator()
        XCTAssertEqual(restored.selectedAlbumIds, coordinator.selectedAlbumIds)
        XCTAssertEqual(restored.wifiOnly, coordinator.wifiOnly)
        XCTAssertEqual(restored.chargingOnly, coordinator.chargingOnly)
        XCTAssertEqual(restored.backupPhotos, coordinator.backupPhotos)
        XCTAssertEqual(restored.backupVideos, coordinator.backupVideos)
        XCTAssertEqual(coordinator.status, "备份偏好已生效")
    }

    @MainActor func testLogoutPersistsWithoutDiscardingReusablePairingCredentials() throws {
        let preferences = MobileContractV1.preferences
        let previousSignOut = preferences.object(forKey: "account_signed_out")
        let oldCode = KeychainStore.load("authorization_code")
        let oldToken = KeychainStore.load(MobileContractV1.tokenKey)
        defer {
            if let previousSignOut { preferences.set(previousSignOut, forKey: "account_signed_out") }
            else { preferences.removeObject(forKey: "account_signed_out") }
            if let oldCode { try? KeychainStore.save(oldCode, for: "authorization_code") }
            else { KeychainStore.delete("authorization_code") }
            if let oldToken { try? KeychainStore.save(oldToken, for: MobileContractV1.tokenKey) }
            else { KeychainStore.delete(MobileContractV1.tokenKey) }
        }
        preferences.set(false, forKey: "account_signed_out")
        try KeychainStore.save("test-instance-code", for: "authorization_code")
        try KeychainStore.save("test-existing-token", for: MobileContractV1.tokenKey)
        let coordinator = BackupCoordinator()
        XCTAssertFalse(coordinator.authorizationCode.isEmpty)
        coordinator.logout()
        XCTAssertTrue(coordinator.authorizationCode.isEmpty)
        XCTAssertNil(coordinator.library)
        XCTAssertTrue(BackupCoordinator().authorizationCode.isEmpty)
        XCTAssertEqual(KeychainStore.load("authorization_code"), "test-instance-code")
        XCTAssertEqual(KeychainStore.load(MobileContractV1.tokenKey), "test-existing-token")
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
