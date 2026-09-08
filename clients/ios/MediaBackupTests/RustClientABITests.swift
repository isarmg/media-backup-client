import XCTest
import UIKit
import MediaBackupRust
@testable import MediaBackup

final class RustClientABITests: XCTestCase {
    func testImportedHeaderMatchesNativeLibraryAndErrorsAreExplicit() {
        XCTAssertEqual(mb_ffi_abi_revision(), UInt32(SARMG_FFI_ABI_REVISION))
        var output = SarmgFfiResultV2()
        XCTAssertEqual(mb_stats_v2(0, &output), Int32(SARMG_FFI_INVALID_HANDLE))
        XCTAssertEqual(output.status, Int32(SARMG_FFI_INVALID_HANDLE))
        XCTAssertEqual(output.value, 0)
        XCTAssertGreaterThan(output.bytes.length, 0)
        XCTAssertEqual(sarmg_ffi_result_free_v2(&output), Int32(SARMG_FFI_OK))
        XCTAssertNil(output.bytes.data)
        XCTAssertEqual(output.bytes.length, 0)
        XCTAssertEqual(sarmg_ffi_result_free_v2(&output), Int32(SARMG_FFI_OK))
    }

    func testPickerPreviewDecodesImageDataAndRejectsOpaqueNames() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        }
        let data = try XCTUnwrap(image.pngData())
        let preview = try XCTUnwrap(PickerPreview.image(data as NSData))
        XCTAssertLessThanOrEqual(max(preview.size.width, preview.size.height), 320)
        XCTAssertNil(PickerPreview.image("opaque-provider-identifier" as NSString))
        XCTAssertNil(PickerPreview.image(try XCTUnwrap(URL(string: "https://example.com/image.jpg")) as NSURL))
    }

    func testNativeFailureDescriptionIsVisible() {
        XCTAssertEqual(ClientFailure.message("备份记录暂时不可用").localizedDescription, "备份记录暂时不可用")
    }

    func testRecreatedAccountKeepsOldQueueAndReloginKeepsCurrentQueue() throws {
        let server = "https://backup.example.com", username = "login-\(UUID().uuidString)"
        let account = UUID(), replacement = UUID()
        var profiles = Set<String>()
        defer {
            if let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false) {
                for profile in profiles { try? FileManager.default.removeItem(at: support.appendingPathComponent(profile)) }
            }
        }
        try autoreleasepool {
            var stores: [String: TransferStore] = [:]
            func login(_ id: UUID) throws -> (profile: String, store: TransferStore) {
                try TransferStore.bindAccount(server: server, username: username, accountId: id, deviceId: UUID()) { key in
                    profiles.insert(key)
                    if let value = stores[key] { return value }
                    let value = try TransferStore(profile: key); stores[key] = value; return value
                }
            }
            let original = try login(account)
            try original.store.client.transfer(["op": "create_batch", "id": UUID().uuidString,
                "items": [["id": "selected", "source": "local-photo"]]])
            XCTAssertEqual(original.profile, try login(account).profile)
            let recreated = try login(replacement)
            XCTAssertNotEqual(original.profile, recreated.profile)
            XCTAssertTrue(try recreated.store.batches().isEmpty)
            XCTAssertEqual(recreated.profile, try login(replacement).profile)
            XCTAssertEqual(try original.store.batches().count, 1)
            let binding = try original.store.client.transfer(["op": "binding"]) as? [String: Any]
            XCTAssertEqual(binding?["account_id"] as? String, account.uuidString)
            XCTAssertEqual(original.profile, try login(account).profile)
            XCTAssertEqual(try original.store.batches().count, 1)
        }
    }

    func testRustClientUsesLengthDelimitedUnicodeAndClosesBeforeReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ffi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent(MobileContractV02.databaseFilename).path
        var client: RustClient? = try RustClient(databasePath: path)
        XCTAssertTrue(try XCTUnwrap(client).needs(asset: "中文😀", resource: "resource", modifiedMs: 1))
        client = nil
        let reopened = try RustClient(databasePath: path)
        XCTAssertTrue(try reopened.needs(asset: "中文😀", resource: "resource", modifiedMs: 1))
        XCTAssertThrowsError(try RustClient(databasePath: root.appendingPathComponent("wrong.sqlite").path))
    }
}
