import XCTest
@testable import TaskManager

final class CloudOverviewTests: XCTestCase {
    let nc = CloudService(id: "cs:Nextcloud-home", name: "Nextcloud", kind: .system, path: "/tmp/nc")
    let od = CloudService(id: "cs:OneDrive-Personal", name: "OneDrive", kind: .system, path: "/tmp/od")
    let inCloud: [(name: String, inCloud: String?)] = [("Desktop", "iCloud Drive"), ("Documents", "iCloud Drive")]

    func suggestions(_ usage: [String: CloudUsage], quota: [String: CloudQuota] = [:],
                     app: [String: CloudUpload.AppProblem] = [:], down: [String: Bool] = [:],
                     folders: [(name: String, inCloud: String?)]? = nil, tm: Bool = true) -> [CloudOverview.Suggestion] {
        CloudOverview.suggestions(services: [nc, od], usage: usage, quota: quota, appProblem: app, serverDown: down,
                                  folders: folders ?? inCloud, hasTimeMachine: tm)
    }

    func testAllBackedUpSaysSo() {
        let s = suggestions([nc.id: CloudUsage(files: 10, onMacBytes: 1_000), od.id: CloudUsage()])
        XCTAssertEqual(s.map(\.id), ["ok"])
    }

    func testStuckUploadsSayWhyAndComeFirst() {
        var u = CloudUsage(); u.notUploaded = 12; u.notUploadedBytes = 3_000_000_000
        let down = suggestions([nc.id: u], down: [nc.id: true])
        XCTAssertEqual(down.first?.id, "stuck:" + nc.id)
        XCTAssertEqual(down.first?.level, .warning)
        XCTAssertTrue(down.first!.detail.contains("can’t reach Nextcloud’s server"))
        XCTAssertEqual(down.first?.action, .checkUploads(nc.id))

        let signedOut = suggestions([nc.id: u], app: [nc.id: .signedOut])
        XCTAssertTrue(signedOut.first!.detail.contains("signed out"), "the app's problem wins over the server")

        var full = u; full.uploadIssues = ["Your cloud storage is full. Free some space online, or get more.": 12]
        XCTAssertTrue(suggestions([nc.id: full]).first!.detail.hasPrefix("Your cloud storage is full"))

        let moving = suggestions([nc.id: u])
        XCTAssertEqual(moving.first?.id, "waiting:" + nc.id, "no reason found: still uploading, not stuck")
        XCTAssertEqual(moving.first?.level, .info)
    }

    func testOldFilesAlreadyInTheCloudAreOfferedForFreeing() {
        var u = CloudUsage()
        u.untouched = [CloudFile(path: "/tmp/od/a.mov", bytes: 400_000_000), CloudFile(path: "/tmp/od/b.mov", bytes: 300_000_000)]
        let s = suggestions([od.id: u])
        let g = s.first { $0.id == "untouched:" + od.id }
        XCTAssertEqual(g?.bytes, 700_000_000)
        XCTAssertEqual(g?.action, .makeOnlineOnly(od.id))
        u.untouched = [CloudFile(path: "/tmp/od/a.mov", bytes: 100_000_000)]
        XCTAssertNil(suggestions([od.id: u]).first { $0.id.hasPrefix("untouched") }, "too little to bother")
    }

    func testNearlyFullOnlineStorage() {
        let u = [nc.id: CloudUsage(), od.id: CloudUsage()]
        let s = suggestions(u, quota: [nc.id: CloudQuota(used: 98, available: 2)])
        XCTAssertEqual(s.first?.id, "full:" + nc.id)
        XCTAssertEqual(s.first?.level, .warning)
        XCTAssertTrue(s.first!.title.contains("98%"))
        XCTAssertEqual(suggestions(u, quota: [nc.id: CloudQuota(used: 91, available: 9)]).first?.level, .notice)
        XCTAssertEqual(suggestions(u, quota: [nc.id: CloudQuota(used: 50, available: 50)]).map(\.id), ["ok"])
    }

    func testDesktopAndDocumentsOutsideAnyCloud() {
        let u = [nc.id: CloudUsage()]
        let none: [(name: String, inCloud: String?)] = [("Desktop", nil), ("Documents", nil)]
        let noBackup = suggestions(u, folders: none, tm: false).first { $0.id == "folders" }
        XCTAssertEqual(noBackup?.level, .warning)
        XCTAssertEqual(noBackup?.title, "Desktop and Documents aren’t in any cloud")
        XCTAssertEqual(suggestions(u, folders: none, tm: true).first { $0.id == "folders" }?.level, .info, "Time Machine has them")
        let one: [(name: String, inCloud: String?)] = [("Desktop", "iCloud Drive"), ("Documents", nil)]
        XCTAssertEqual(suggestions(u, folders: one).first { $0.id == "folders" }?.title, "Documents isn’t in any cloud")
    }

    func testTotalsAndKinds() {
        var a = CloudUsage(onlineOnly: 3, onMacBytes: 100); a.kinds = ["Videos": 80, "Other": 20]; a.notUploaded = 1; a.notUploadedBytes = 5
        var b = CloudUsage(onlineOnly: 2, onMacBytes: 50); b.kinds = ["Photos": 50, "Other": 0]
        let t = CloudOverview.totals([a, b])
        XCTAssertEqual(t.onMac, 150)
        XCTAssertEqual(t.onlineOnlyFiles, 5)
        XCTAssertEqual(t.notUploaded, 1)
        XCTAssertEqual(CloudOverview.kinds([a, b]).map(\.kind), ["Videos", "Photos", "Other"])
    }

    func testFileKinds() {
        XCTAssertEqual(Cloud.kind(of: "MOV"), "Videos")
        XCTAssertEqual(Cloud.kind(of: "heic"), "Photos")
        XCTAssertEqual(Cloud.kind(of: "pdf"), "Documents")
        XCTAssertEqual(Cloud.kind(of: "dmg"), "Archives and installers")
        XCTAssertEqual(Cloud.kind(of: ""), "Other")
    }

    func testUploadReasonsInPlainWords() {
        XCTAssertEqual(Cloud.uploadReason(domain: "NSFileProviderErrorDomain", code: -1004, text: "x"), "Can’t reach the server.")
        XCTAssertEqual(Cloud.uploadReason(domain: "NSFileProviderErrorDomain", code: -1000, text: "x"), "The app needs you to sign in again.")
        XCTAssertEqual(Cloud.uploadReason(domain: "Other", code: 1, text: "Disk on fire"), "Disk on fire")
    }

    func testPersonalFoldersFollowTheLinkIntoICloud() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("apex-home-\(UUID())").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let icloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        try FileManager.default.createDirectory(atPath: icloud + "/Desktop", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/Documents", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/Desktop", withDestinationPath: icloud + "/Desktop")
        let f = Cloud.personalFolders(home: home, clouds: [])
        XCTAssertEqual(f.first { $0.name == "Desktop" }?.inCloud, "iCloud Drive")
        XCTAssertNil(f.first { $0.name == "Documents" }!.inCloud)
    }

    func testScanFindsFilesNotOpenedForMonths() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-cloud-old-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 7, count: 2_000_000).write(to: dir.appendingPathComponent("clip.mov"))
        let u = Cloud.scan(dir.path, now: Date().addingTimeInterval(200 * 86400))
        XCTAssertEqual(u.kinds["Videos"].map { $0 >= 2_000_000 }, true)
        XCTAssertTrue(u.untouched.isEmpty, "a plain folder isn’t in a cloud, so it’s never offered for online-only")
        XCTAssertEqual(u.notUploaded, 0, "and it isn’t counted as waiting to upload either")
    }
}

final class CloudOverviewAllClearTests: XCTestCase {
    func testNoAllClearWhileAServiceIsUnchecked() {
        let a = CloudService(id: "a", name: "A", kind: .system, path: "/a")
        let b = CloudService(id: "b", name: "B", kind: .system, path: "/b")
        let one = CloudOverview.suggestions(services: [a, b], usage: ["a": CloudUsage()], quota: [:], appProblem: [:], serverDown: [:],
                                            folders: [], hasTimeMachine: true)
        XCTAssertFalse(one.contains { $0.id == "ok" }, "B hasn't been checked yet")
        XCTAssertEqual(one.first { $0.id == "checking" }?.title, "Checking B…")
        let both = CloudOverview.suggestions(services: [a, b], usage: ["a": CloudUsage(), "b": CloudUsage()], quota: [:], appProblem: [:],
                                             serverDown: [:], folders: [], hasTimeMachine: true)
        XCTAssertTrue(both.contains { $0.id == "ok" })
    }
}
