import XCTest
@testable import TaskManager

/// The security review's fixes, each tried with the input an attacker would use.
final class SecurityTests: XCTestCase {
    func testArchiveNamesCantLeaveTheirFolder() throws {
        XCTAssertEqual(ArchiveList.clean("../../.zshrc"), ".zshrc")
        XCTAssertEqual(ArchiveList.clean("a/../../b/./c"), "a/b/c")
        XCTAssertEqual(ArchiveList.clean("/etc/passwd"), "etc/passwd")
        XCTAssertEqual(ArchiveList.clean("..\\..\\win.ini"), "win.ini")
        // A real archive with a "../../" name: opening that file in the preview stays inside the temporary folder.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-sec-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = dir.appendingPathComponent("evil.zip")
        let py = Process(); py.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        py.arguments = ["-I", "-c", "import zipfile,sys\nwith zipfile.ZipFile(sys.argv[1],'w') as z: z.writestr('../../escaped.txt','x')", zip.path]
        try py.run(); py.waitUntilExit()
        let items = try ArchiveList.items(zip)
        XCTAssertEqual(items.map(\.path), ["escaped.txt"], "listed under a safe name")
        let entry = FolderEntry(name: "escaped.txt", path: zip.path + "/escaped.txt", isFolder: false, size: 1, modified: nil,
                                archive: zip.path, inner: items[0].path)
        let exp = expectation(description: "opened")
        Task {
            let u = try await FolderPreviewModel.fileURL(for: entry)
            XCTAssertTrue(u.path.contains("/Apex Preview/"), u.path)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: FileManager.default.temporaryDirectory.deletingLastPathComponent().appendingPathComponent("escaped.txt").path))
    }

    func testSSHHostsCantBecomeOptions() {
        XCTAssertFalse(ServerConfig.isSafe("-oProxyCommand=open -a Calculator"))
        XCTAssertFalse(ServerConfig.isSafe("host name"))
        XCTAssertFalse(ServerConfig.isSafe("host\nx"))
        XCTAssertTrue(ServerConfig.isSafe("server.example.com"))
        XCTAssertTrue(ServerConfig.isSafe("192.168.1.10"))
        var s = ServerConfig(id: UUID(), name: "x", host: "-oProxyCommand=touch /tmp/pwned")
        let args = ServerClient.connectionArguments(s, socketDir: nil)
        XCTAssertEqual(args.suffix(2), ["--", "invalid-host.invalid"], "an unsafe host is never handed to ssh")
        s.host = "example.com"
        XCTAssertEqual(ServerClient.connectionArguments(s, socketDir: nil).suffix(2), ["--", "example.com"], "options always end before the host")
    }

    func testDockerCommandsCantRunAnythingElse() {
        XCTAssertTrue(LocalDocker.isPlainCommand("docker exec 'web' kill -9 123"))
        XCTAssertTrue(LocalDocker.isPlainCommand("docker stop 'name; with semicolon'"), "inside quotes is only a name")
        XCTAssertFalse(LocalDocker.isPlainCommand("docker ps; rm -rf ~"))
        XCTAssertFalse(LocalDocker.isPlainCommand("docker ps && curl x | sh"))
        XCTAssertFalse(LocalDocker.isPlainCommand("docker ps `id`"))
        XCTAssertFalse(LocalDocker.isPlainCommand("docker ps $(id)"))
        XCTAssertFalse(LocalDocker.isPlainCommand("docker ps > ~/.zshrc"))
        XCTAssertFalse(LocalDocker.isPlainCommand("docker ps 'unclosed"))
        XCTAssertEqual(LocalDocker.action("docker ps; touch /tmp/apex-pwned").launched, false)
    }

    func testPasswordsNeverGoOverPlainHTTP() async {
        let r = await Cloud.quota(url: "http://nas.local/remote.php/dav", username: "me", password: "secret")
        guard case .failure(let e) = r else { return XCTFail("refused before any request") }
        XCTAssertTrue(e.localizedDescription.contains("https"))
    }
}
