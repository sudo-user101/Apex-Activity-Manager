import CoreAudio
import XCTest
@testable import TaskManager

final class WindowTweaksTests: XCTestCase {
    let area = CGRect(x: 0, y: 25, width: 1440, height: 875)       // a screen under the menu bar, top-left origin

    func testBrightnessSteps() {
        XCTAssertEqual(WindowTweaks.steppedBrightness(0.5, +1), 0.5625, accuracy: 0.0001)
        XCTAssertEqual(WindowTweaks.steppedBrightness(0.51, -1), 0.4375, accuracy: 0.0001, "from between steps it lands on a step")
        XCTAssertEqual(WindowTweaks.steppedBrightness(1, +1), 1)
        XCTAssertEqual(WindowTweaks.steppedBrightness(0.02, -1), 0)
    }

    func testHeadphones() {
        XCTAssertTrue(WindowTweaks.isHeadphones(transport: kAudioDeviceTransportTypeBluetooth, dataSource: nil, name: "Speaker"))
        XCTAssertTrue(WindowTweaks.isHeadphones(transport: kAudioDeviceTransportTypeBuiltIn, dataSource: 0x6864_706E, name: "MacBook Pro Speakers"),
                      "the headphone jack")
        XCTAssertFalse(WindowTweaks.isHeadphones(transport: kAudioDeviceTransportTypeBuiltIn, dataSource: 0x6973_706B, name: "MacBook Pro Speakers"))
        XCTAssertTrue(WindowTweaks.isHeadphones(transport: kAudioDeviceTransportTypeUSB, dataSource: nil, name: "USB Headset"))
        XCTAssertFalse(WindowTweaks.isHeadphones(transport: kAudioDeviceTransportTypeHDMI, dataSource: nil, name: "LG Monitor"))
    }
}
