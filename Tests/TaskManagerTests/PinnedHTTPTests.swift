import XCTest
@testable import TaskManager

final class PinnedHTTPTests: XCTestCase {
    func testParsesPlainAndChunked() throws {
        let plain = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"a\":true}\nEXTRA".utf8)
        let p = try XCTUnwrap(PinnedHTTP.parse(plain))
        XCTAssertEqual(p.status, 200)
        XCTAssertEqual(String(decoding: p.body, as: UTF8.self), "{\"a\":true}\n")
        let chunked = Data("HTTP/1.1 401 Unauthorized\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"er\r\n6\r\nror\":1\r\n1\r\n}\r\n0\r\n\r\n".utf8)
        let c = try XCTUnwrap(PinnedHTTP.parse(chunked))
        XCTAssertEqual(c.status, 401)
        XCTAssertEqual(String(decoding: c.body, as: UTF8.self), "{\"error\":1}")
        XCTAssertNil(PinnedHTTP.parse(Data("garbage".utf8)))
    }

    func testRequestBytes() {
        let r = String(decoding: PinnedHTTP.request(host: "fe80::1", port: 7443, method: "POST", path: "/api/docker",
                                                    headers: ["Authorization": "Bearer t", "X-Bad": "a\r\nInjected: 1"], body: Data("{}".utf8)), as: UTF8.self)
        XCTAssertTrue(r.hasPrefix("POST /api/docker HTTP/1.1\r\nHost: [fe80::1]:7443\r\n"))
        XCTAssertTrue(r.contains("Authorization: Bearer t\r\n"))
        XCTAssertFalse(r.contains("Injected"), "a header can't add another")
        XCTAssertTrue(r.hasSuffix("Content-Length: 2\r\n\r\n{}"))
    }

    /// APEX_HELLO_HOSTS=host:port,host:port: the public hello of real servers,
    /// any certificate, then refused with a wrong pin.
    func testLiveHello() throws {
        guard let list = ProcessInfo.processInfo.environment["APEX_HELLO_HOSTS"] else { throw XCTSkip("set APEX_HELLO_HOSTS") }
        for hp in list.split(separator: ",") {
            let p = hp.split(separator: ":").map(String.init)
            let r = PinnedHTTP.send(host: p[0], port: Int(p[1])!, path: "/api/hello", expected: nil, timeout: 10)
            guard case .success(let ok) = r else { return XCTFail("\(hp): \(r)") }
            XCTAssertEqual(ok.status, 200)
            XCTAssertTrue(String(decoding: ok.body, as: UTF8.self).contains("Apex"))
            XCTAssertNotNil(ok.key, "its key pin")
            print("APEX-HELLO", hp, ok.fingerprint.prefix(11), "key", ok.key?.prefix(11) ?? "-")
            let wrong = PinnedHTTP.send(host: p[0], port: Int(p[1])!, path: "/api/hello", expected: "AA:BB", timeout: 10)
            XCTAssertEqual(wrong.failureValue, .wrongCertificate, "\(hp): another certificate is refused")
        }
    }
}

private extension Result {
    var failureValue: Failure? { if case .failure(let f) = self { return f }; return nil }
}
