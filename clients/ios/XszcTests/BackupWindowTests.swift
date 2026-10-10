import XCTest
import UIKit
@testable import Xszc

final class BackupWindowTests: XCTestCase {
    // Actual SelectedMedia import, image thumbnail generation and Rust queue operations.
    // Completion is local; this does not exercise PhotoKit export, network or BGTask scheduling.
    @MainActor
    func testWindowBoundaryKeepsSelectionPendingAndNextRunCompletesIt() async throws {
        let profile = "backup-window-test-\(UUID().uuidString)"
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        defer { try? FileManager.default.removeItem(at: support.appendingPathComponent(profile)) }
        let store = try TransferStore(profile: profile)
        let batch = UUID().uuidString
        let image = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 8)).pngData { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        }
        var items: [[String: Any]] = []
        for index in 0..<32 {
            let path = store.staging.appendingPathComponent("sources/\(UUID().uuidString).png")
            try image.write(to: path)
            let descriptor: [String: Any] = ["kind": "import", "source_id": "window-photo-\(index)",
                "path": path.path, "name": "photo-\(index).png", "mime": "image/png", "size": image.count,
                "created_ms": 1000, "video": false]
            let data = try JSONSerialization.data(withJSONObject: descriptor)
            items.append(["id": "item-\(index)", "source": String(decoding: data, as: UTF8.self)])
        }
        try store.client.transfer(["op": "create_batch", "id": batch, "items": items])
        var processed = 0
        var completedJobs = Set<String>()
        func drain() async throws {
            while let job = try store.client.next(stagingRoot: store.staging.path) {
                try BackupCoordinator.checkUploadBudget(processed)
                XCTAssertTrue(completedJobs.insert(job.jobId).inserted, "Completed originals must not be uploaded twice")
                if job.request.role == "primary" {
                    var original = Data()
                    for part in job.localParts { original.append(try Data(contentsOf: URL(fileURLWithPath: part.path))) }
                    XCTAssertEqual(original, image)
                }
                try store.client.markComplete(job: job.jobId)
                processed += 1
            }
        }
        do {
            try await BackupCoordinator.preparePendingUploads(store: store, checkCurrent: {}, drain: drain)
            XCTFail("The 60-resource window must end before visiting later selections")
        } catch CoordinatorFailure.windowComplete { }
        XCTAssertEqual(processed, 60)
        let paused = try XCTUnwrap(try store.batches().first)
        XCTAssertEqual(paused.complete, 30)
        XCTAssertEqual(paused.items[30]["state"] as? String, "pending")
        XCTAssertNil(paused.items[30]["error"] as? String)
        XCTAssertEqual(paused.items[31]["state"] as? String, "pending")
        XCTAssertEqual(paused.items[31]["resources"] as? Int, 0, "Do not export later selections after the window ends")
        XCTAssertEqual(try store.nextPendingUpload()?.item, "item-30")

        // A later run drains durable work first, exactly as runBackup does.
        processed = 0
        try await drain()
        try await BackupCoordinator.preparePendingUploads(store: store, checkCurrent: {}, drain: drain)
        let complete = try XCTUnwrap(try store.batches().first)
        XCTAssertTrue(complete.isCompleted)
        XCTAssertEqual(complete.complete, 32)
        XCTAssertEqual(completedJobs.count, 64)
        XCTAssertNil(try store.nextPendingUpload())
    }

    @MainActor
    func testMissingOriginalPreparationStillBlocksItem() async throws {
        let profile = "backup-window-failure-\(UUID().uuidString)"
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        defer { try? FileManager.default.removeItem(at: support.appendingPathComponent(profile)) }
        let store = try TransferStore(profile: profile)
        let batch = UUID().uuidString
        let missing = store.staging.appendingPathComponent("sources/missing-original.png")
        let descriptor: [String: Any] = ["kind": "import", "source_id": "missing-photo",
            "path": missing.path, "name": "missing.png", "mime": "image/png", "size": 8, "video": false]
        let data = try JSONSerialization.data(withJSONObject: descriptor)
        try store.client.transfer(["op": "create_batch", "id": batch,
            "items": [["id": "unavailable", "source": String(decoding: data, as: UTF8.self)]]])
        try await BackupCoordinator.preparePendingUploads(store: store, checkCurrent: {}, drain: {
            _ = try store.client.next(stagingRoot: store.staging.path)
            XCTFail("Missing originals must fail actual native preparation")
        })
        let item = try XCTUnwrap(try store.batches().first?.items.first)
        XCTAssertEqual(item["state"] as? String, "blocked")
        XCTAssertNotNil(item["error"] as? String)
    }
}
