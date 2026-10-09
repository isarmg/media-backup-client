import XCTest
@testable import Xszc

final class LocalGalleryTests: XCTestCase {
    func testPageBoundariesDoNotLoseOrRepeatPhotosAndVideos() throws {
        for total in [149, 150, 151, 300, 301, 453] {
            try withCatalog(count: total) { store in
                var ids: [String] = []
                while true {
                    let page = try LocalCatalog.window(store: store, album: nil, kind: nil,
                        unbacked: false, offset: ids.count)
                    ids += page.rows.map(\.id)
                    if !page.hasMore { break }
                    XCTAssertEqual(page.rows.count, 150)
                    XCTAssertLessThan(ids.count, total)
                }
                XCTAssertEqual(ids, (0..<total).reversed().map(Self.id))
                XCTAssertEqual(Set(ids).count, total)
            }
        }
    }

    func testRefreshRestoresTheLoadedWindowAndFindsTheRealEnd() throws {
        try withCatalog(count: 453) { store in
            let refreshed = try LocalCatalog.window(store: store, album: nil, kind: nil,
                unbacked: false, count: 300)
            XCTAssertEqual(refreshed.rows.count, 300)
            XCTAssertTrue(refreshed.hasMore)
            let remaining = try LocalCatalog.window(store: store, album: nil, kind: nil,
                unbacked: false, offset: 300, count: 153)
            XCTAssertEqual(remaining.rows.count, 153)
            XCTAssertFalse(remaining.hasMore)
            let all = try LocalCatalog.window(store: store, album: nil, kind: nil,
                unbacked: false, count: 453)
            XCTAssertEqual(all.rows.map(\.id), refreshed.rows.map(\.id) + remaining.rows.map(\.id))
            XCTAssertFalse(all.hasMore)
        }
    }

    func testPaginationAppliesAlbumAndVideoFiltersBeforeCountingPages() throws {
        try withCatalog(count: 1003) { store in
            var ids: [String] = []
            while true {
                let page = try LocalCatalog.window(store: store, album: "a", kind: "video",
                    unbacked: true, offset: ids.count)
                XCTAssertTrue(page.rows.allSatisfy { $0.kind == "video" })
                ids += page.rows.map(\.id)
                if !page.hasMore { break }
            }
            let expected = (0..<1003).reversed().filter { $0.isMultiple(of: 6) }.map(Self.id)
            XCTAssertEqual(ids, expected)
            XCTAssertEqual(Set(ids).count, expected.count)
        }
    }

    private static func id(_ index: Int) -> String { String(format: "media-%06d", index) }

    private func withCatalog(count: Int, body: (TransferStore) throws -> Void) throws {
        let profile = "local-pagination-test-\(UUID().uuidString)"
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        defer { try? FileManager.default.removeItem(at: support.appendingPathComponent(profile)) }
        let store = try TransferStore(profile: profile)
        try store.gallery(["op": "begin_catalog"])
        for offset in stride(from: 0, to: count, by: 200) {
            let items: [[String: Any]] = (offset..<min(count, offset + 200)).map { index in
                ["source_id": Self.id(index), "name": "media-\(index)",
                 "media_kind": index.isMultiple(of: 3) ? "video" : "photo",
                 "album_id": index.isMultiple(of: 2) ? "a" : "b",
                 "created_ms": Int64(index * 1000), "modified_ms": Int64(index * 1000),
                 "size": 0, "descriptor": "{}"]
            }
            try store.gallery(["op": "catalog", "items": items])
        }
        try store.gallery(["op": "finish_catalog"])
        try body(store)
    }
}
