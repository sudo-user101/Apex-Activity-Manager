import XCTest
@testable import TaskManager

final class AppAudioTests: XCTestCase {
    func testHelpersBelongToTheirApp() {
        XCTAssertEqual(AppAudio.ownerBundle("com.google.Chrome.helper.renderer"), "com.google.Chrome")
        XCTAssertEqual(AppAudio.ownerBundle("com.google.Chrome.helper"), "com.google.Chrome")
        XCTAssertEqual(AppAudio.ownerBundle("com.microsoft.edgemac.helper"), "com.microsoft.edgemac")
        XCTAssertEqual(AppAudio.ownerBundle("com.spotify.client.helper"), "com.spotify.client")
        XCTAssertEqual(AppAudio.ownerBundle("org.mozilla.firefox.plugincontainer"), "org.mozilla.firefox")
        XCTAssertEqual(AppAudio.ownerBundle("com.apple.Music"), "com.apple.Music", "an app is its own owner")
        XCTAssertEqual(AppAudio.ownerBundle("helper"), "helper", "nothing in front to keep")
    }

    func testVolumeCurveAndWhenATapIsNeeded() {
        XCTAssertEqual(AppAudio.gain(1, muted: false), 1)
        XCTAssertEqual(AppAudio.gain(0.5, muted: false), 0.25, accuracy: 0.0001, "squared: half way sounds about half as loud")
        XCTAssertEqual(AppAudio.gain(0.8, muted: true), 0)
        XCTAssertEqual(AppAudio.gain(1.7, muted: false), 1, "never louder than the app itself")
        XCTAssertEqual(AppAudio.gain(-1, muted: false), 0)
        XCTAssertFalse(AppAudio.needsTap(1, muted: false), "full volume: no tap, nothing runs")
        XCTAssertTrue(AppAudio.needsTap(0.9, muted: false))
        XCTAssertTrue(AppAudio.needsTap(1, muted: true))
    }

    func testMixScalesAndFillsTheRestWithSilence() {
        let src: [Float] = [1, -1, 0.5, -0.5]
        var dst = [Float](repeating: 9, count: 6)
        src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in AppAudio.mix(s.baseAddress, count: 4, into: d.baseAddress!, count: 6, gain: 0.5) }
        }
        XCTAssertEqual(dst, [0.5, -0.5, 0.25, -0.25, 0, 0])
        var silent = [Float](repeating: 9, count: 3)
        silent.withUnsafeMutableBufferPointer { d in AppAudio.mix(nil, count: 0, into: d.baseAddress!, count: 3, gain: 1) }
        XCTAssertEqual(silent, [0, 0, 0], "no input: silence, never old data")
        var short = [Float](repeating: 9, count: 2)
        src.withUnsafeBufferPointer { s in
            short.withUnsafeMutableBufferPointer { d in AppAudio.mix(s.baseAddress, count: 4, into: d.baseAddress!, count: 2, gain: 1) }
        }
        XCTAssertEqual(short, [1, -1], "never writes past the output buffer")
    }

    func testMediaKeyEventData() {
        XCTAssertEqual(MediaKeys.data1(.playPause, down: true), (16 << 16) | (0xA << 8))
        XCTAssertEqual(MediaKeys.data1(.next, down: false), (17 << 16) | (0xB << 8))
        XCTAssertEqual(MediaKeys.data1(.previous, down: true), (18 << 16) | (0xA << 8))
    }

    /// Reads Core Audio on this Mac: whatever is listed must be grouped by app, once each.
    func testListingAppsWithSoundOnThisMac() {
        let apps = AppAudio.apps()
        XCTAssertEqual(Set(apps.map(\.bundleID)).count, apps.count, "one row per app")
        XCTAssertFalse(apps.contains { $0.objects.isEmpty })
        XCTAssertFalse(apps.contains { $0.pid == getpid() }, "not Apex itself")
    }
}
