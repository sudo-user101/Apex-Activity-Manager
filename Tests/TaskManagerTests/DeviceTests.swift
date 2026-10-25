import XCTest
@testable import TaskManager

final class DeviceTests: XCTestCase {
    func drive(_ id: String) -> StorageDevice {
        StorageDevice(id: id, name: "T7", model: "Samsung T7", connection: "USB", isInternal: false, ejectable: true,
                      size: 1_000_000_000_000, volumes: [], registryID: 1)
    }
    func adapter(_ id: String) -> NetworkDevice {
        NetworkDevice(id: id, name: "USB 10/100/1000 LAN", connection: "USB", kind: "Ethernet", hardwareAddress: "")
    }

    func testSidebarPlacesDevicesUnderTheirKind() {
        var s = SystemSnapshot()
        XCTAssertEqual(PerfItem.all(s).count, Resource.allCases.count, "nothing plugged in: the fixed pages only")
        s.storageDevices = [drive("disk6"), drive("disk8")]
        s.networkDevices = [adapter("en7")]
        let keys = PerfItem.all(s).map(\.key)
        XCTAssertEqual(keys, ["cpu", "memory", "disk", "disk:disk6", "disk:disk8", "cloud", "network", "net:en7", "gpu", "display", "battery", "sensors"])
        XCTAssertEqual(PerfItem(key: "disk:disk6").resource, .disk, "drives are tabs under Storage")
        XCTAssertEqual(PerfItem(key: "net:en7").resource, .network)
        XCTAssertEqual(PerfItem.siblings(of: .disk("disk6"), in: s).map(\.0.key), ["disk", "disk:disk6", "disk:disk8"])
    }

    func testItemKeysRoundTrip() {
        for item in [PerfItem.resource(.memory), .disk("disk6"), .net("en7")] {
            XCTAssertEqual(PerfItem(key: item.key), item)
        }
        XCTAssertEqual(PerfItem(key: "nonsense"), .resource(.cpu))
        XCTAssertEqual(PerfItem(key: "memory"), .resource(.memory), "old saved selections still work")
    }

    func testConnectionNames() {
        XCTAssertEqual(DeviceScanner.connectionName("USB", internal: false), "USB")
        XCTAssertEqual(DeviceScanner.connectionName("Thunderbolt", internal: false), "Thunderbolt")
        XCTAssertEqual(DeviceScanner.connectionName("PCI-Express", internal: false), "Thunderbolt")
        XCTAssertEqual(DeviceScanner.connectionName("PCI-Express", internal: true), "Internal")
        XCTAssertEqual(DeviceScanner.connectionName("Secure Digital", internal: true), "SD card")
        XCTAssertEqual(DeviceScanner.connectionName("", internal: false), "External")
        XCTAssertEqual(DeviceScanner.kindName("IEEE80211"), "Wi-Fi")
        XCTAssertEqual(DeviceScanner.kindName("Ethernet"), "Ethernet")
    }

    func testHistoryDropsUnpluggedDevices() {
        var h = History()
        var s = SystemSnapshot()
        var d = drive("disk6"); d.readPerSec = 100; d.writePerSec = 50
        s.storageDevices = [d]
        s.networkDevices = [adapter("en7")]
        let t = Date()
        h.push(s, at: t)
        h.push(s, at: t.addingTimeInterval(1))
        XCTAssertEqual(h.devices["disk:disk6"]?.a, [100, 100])
        XCTAssertEqual(h.devices["disk:disk6"]?.times.count, 2)
        XCTAssertNotNil(h.devices["net:en7"])
        s.storageDevices = []                       // unplugged
        h.push(s, at: t.addingTimeInterval(2))
        XCTAssertNil(h.devices["disk:disk6"])
        XCTAssertNotNil(h.devices["net:en7"])
    }

    func testDeviceSeriesKeepsTenMinutes() {
        var ds = DeviceSeries()
        let t = Date()
        for i in 0..<700 { ds.push(t.addingTimeInterval(Double(i)), Double(i), 0) }
        XCTAssertLessThanOrEqual(ds.times.count, 602)
        XCTAssertEqual(ds.times.count, ds.a.count)
        XCTAssertEqual(ds.a.last, 699)
    }

    func testCapacityAddsVolumes() {
        var d = drive("disk6")
        d.volumes = [VolumeInfo(name: "A", path: "/Volumes/A", capacity: 100, available: 40, format: "APFS"),
                     VolumeInfo(name: "B", path: "/Volumes/B", capacity: 50, available: 10, format: "ExFAT")]
        XCTAssertEqual(d.capacity, 150)
        XCTAssertEqual(d.available, 50)
    }
}

final class RouterLookupTests: XCTestCase {
    func testParsesUPnPDescription() {
        let xml = """
        <?xml version="1.0"?><root><device><deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType>
        <friendlyName>MW302R 300Mbps Multi-Mode Wireless N Router</friendlyName><manufacturer>MERCUSYS</manufacturer>
        <modelName>MW302R</modelName><deviceList><device><friendlyName>WAN Device</friendlyName></device></deviceList></device></root>
        """
        let u = RouterLookup.parseDescription(xml)
        XCTAssertEqual(u.friendly, "MW302R 300Mbps Multi-Mode Wireless N Router", "the root device, not a sub-device")
        XCTAssertEqual(u.manufacturer, "MERCUSYS")
        XCTAssertEqual(u.model, "MW302R")
        XCTAssertEqual(RouterLookup.parseDescription("<friendlyName>A &amp; B</friendlyName>").friendly, "A & B")
    }

    func testLocationHeaderAndNames() {
        let reply = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=100\r\nLocation: http://172.16.0.101:1900/igd.xml\r\nST: x\r\n\r\n"
        XCTAssertEqual(RouterLookup.locationHeader(reply), "http://172.16.0.101:1900/igd.xml")
        XCTAssertNil(RouterLookup.locationHeader("HTTP/1.1 200 OK\r\n\r\n"))
        XCTAssertEqual(RouterLookup.cleanName("router.home."), "router.home")
        XCTAssertTrue(RouterLookup.isIPv4("172.16.0.101"))
        XCTAssertFalse(RouterLookup.isIPv4("fe80::1"))
        XCTAssertFalse(RouterLookup.isIPv4(""))
        var r = RouterIdentity(); r.friendlyName = "Router"; r.manufacturer = "MERCUSYS"; r.model = "MW302R"
        XCTAssertEqual(r.displayName, "Router")
        r.dnsName = "router.home"
        XCTAssertEqual(r.displayName, "router.home", "a DNS name wins")
        XCTAssertEqual(r.modelLine, "MERCUSYS MW302R")
    }

    func testNetworkTabsAreNamedByKind() {
        func dev(_ id: String, _ kind: String, _ conn: String, _ adapter: String) -> NetworkDevice {
            NetworkDevice(id: id, name: adapter, connection: conn, kind: kind, hardwareAddress: "", adapter: adapter)
        }
        let named = DeviceScanner.named([
            dev("en8", "Ethernet", "USB", "USB 10/100/1000 LAN"),
            dev("en10", "Network", "USB", "iPhone USB"),
            dev("en0", "Ethernet", "Built-in", "Ethernet"),
            dev("en1", "Wi-Fi", "Built-in", "Wi-Fi"),
        ])
        XCTAssertEqual(named.map(\.name), ["Wi-Fi", "Ethernet", "Ethernet 2", "iPhone USB"])
        XCTAssertEqual(named.map(\.id), ["en1", "en0", "en8", "en10"], "built-in port before plugged-in adapters")
        XCTAssertEqual(named[2].adapter, "USB 10/100/1000 LAN", "what macOS calls it is kept for the subtitle")
    }
}

final class BluetoothPowerTests: XCTestCase {
    func testGuessFromClassAndName() {
        XCTAssertEqual(BluetoothType.guess(major: 0x04, minor: 0x06, name: "WH-1000XM4"), .headphones)
        XCTAssertEqual(BluetoothType.guess(major: 0x04, minor: 0x05, name: "Kitchen"), .speaker)
        XCTAssertEqual(BluetoothType.guess(major: 0x04, minor: 0x01, name: "AirPods Pro"), .earbuds)
        XCTAssertEqual(BluetoothType.guess(major: 0x05, minor: 0x10, name: "Magic Keyboard"), .keyboard)
        XCTAssertEqual(BluetoothType.guess(major: 0x05, minor: 0x20, name: "Magic Mouse"), .mouse)
        XCTAssertEqual(BluetoothType.guess(major: 0x05, minor: 0x20, name: "Magic Trackpad"), .trackpad)
        XCTAssertEqual(BluetoothType.guess(major: 0x1F, minor: 0, name: "Thing"), .other)
    }

    func testEstimatesAreRangesAndHonest() {
        XCTAssertEqual(BluetoothType.speaker.estimateText, "about 1–5 W")
        XCTAssertEqual(BluetoothType.earbuds.estimateText, "about 20–60 mW")
        XCTAssertNil(BluetoothType.phone.estimateText, "phones vary too much to guess")
        for t in BluetoothType.allCases { if let w = t.typicalWatts { XCTAssertLessThan(w.lowerBound, w.upperBound) } }
    }
}

final class DisplayTests: XCTestCase {
    func testDDCPackets() {
        // Set brightness to 50: length|0x80, "set VCP", code, value hi/lo, checksum.
        let set = DDC.setPacket(code: DDC.brightness, value: 50)
        XCTAssertEqual(Array(set.prefix(5)), [0x84, 0x03, 0x10, 0x00, 0x32])
        let setChk: UInt8 = 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x00 ^ 0x32
        XCTAssertEqual(set.last, setChk)
        let get = DDC.getPacket(code: DDC.brightness)
        let chk: UInt8 = 0x6E ^ 0x51 ^ 0x82 ^ 0x01 ^ 0x10
        XCTAssertEqual(get, [0x82, 0x01, 0x10, chk])
    }

    func testDDCReplyParsing() {
        // src, length, "VCP reply", result OK, code, type, max 100, current 70, checksum.
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x46, 0x00, 0x00]
        let v = DDC.parseReply(reply, code: 0x10)
        XCTAssertEqual(v?.max, 100)
        XCTAssertEqual(v?.current, 70)
        var unsupported = reply; unsupported[3] = 0x01
        XCTAssertNil(DDC.parseReply(unsupported, code: 0x10), "the monitor said it doesn't support that control")
        XCTAssertNil(DDC.parseReply(reply, code: 0x12), "a reply about another control")
    }

    func testModesSortLargestSharpFirst() {
        func m(_ w: Int, _ px: Int, _ hz: Double, _ id: Int32) -> DisplayModeChoice {
            DisplayModeChoice(id: id, pointsWide: w, pointsHigh: w * 10 / 16, pixelsWide: px, pixelsHigh: px * 10 / 16,
                              refresh: hz, isNative: false, isCurrent: false)
        }
        let sorted = Displays.sortedModes([m(1280, 1280, 60, 1), m(1440, 2880, 60, 2), m(1280, 2560, 60, 3), m(1440, 2880, 120, 4)])
        XCTAssertEqual(sorted.map(\.id), [4, 2, 3, 1])
    }
}

@MainActor
final class MenuBarTests: XCTestCase {
    func testKeepAwakeRemainingText() {
        let k = KeepAwake.shared
        k.start(for: 5400, keepDisplayOn: false)
        XCTAssertEqual(k.remainingText(), "1h 29m left")
        k.start(for: nil, keepDisplayOn: false)
        XCTAssertEqual(k.remainingText(), "On until you turn it off")
        k.stop()
        XCTAssertFalse(k.isOn)
        XCTAssertEqual(k.remainingText(), "")
    }

    func testClipboardSkipsPasswordManagerItems() {
        XCTAssertTrue(ClipboardHistory.skipTypes.contains("org.nspasteboard.ConcealedType"))
        XCTAssertTrue(ClipboardHistory.skipTypes.contains("org.nspasteboard.TransientType"))
    }
}

final class AccessoryRulesTests: XCTestCase {
    func testRegularMeansThreeDaysInTwoWeeks() {
        let today = Date(timeIntervalSince1970: 1_790_000_000)
        func d(_ ago: Double) -> String { BluetoothUsage.day(today.addingTimeInterval(-ago * 86400)) }
        XCTAssertFalse(BluetoothUsage.isRegular([d(0), d(1)], today: today), "two days isn't regular yet")
        XCTAssertTrue(BluetoothUsage.isRegular([d(0), d(3), d(9)], today: today))
        XCTAssertFalse(BluetoothUsage.isRegular([d(0), d(20), d(30)], today: today), "old days don't count")
        XCTAssertFalse(BluetoothUsage.isRegular([d(0), d(0), d(0)], today: today), "the same day counts once")
    }

    func testPowerModeParsing() {
        XCTAssertEqual(PowerMode.parse(" lowpowermode         1\n hibernatemode 3"), .low)
        XCTAssertEqual(PowerMode.parse(" powermode            2"), .high)
        XCTAssertEqual(PowerMode.parse(" powermode            0"), .automatic)
        XCTAssertNil(PowerMode.parse(" lowpowermode         0"), "falls back to ProcessInfo")
    }
}

final class SpeedTestTests: XCTestCase {
    func testParsesNetworkQualityJSON() {
        let json = #"{"dl_throughput": 123456789, "ul_throughput": 21000000, "responsiveness": 640, "interface_name": "en0"}"#
        let r = SpeedResult.parse(json)
        XCTAssertEqual(r?.downloadText, "123 Mb/s")
        XCTAssertEqual(r?.uploadText, "21 Mb/s")
        XCTAssertEqual(r?.responsiveness, 640)
        XCTAssertNil(SpeedResult.parse("not json"))
        XCTAssertEqual(SpeedResult.bits(1.5e9), "1.50 Gb/s")
    }
}

final class AirPlayTests: XCTestCase {
    func testFeatureBitsTellVideoFromAudio() {
        XCTAssertTrue(AirPlayDevice.supportsVideo(features: "0x5A7FFFF7,0x1E"), "Apple TV: video + mirroring")
        XCTAssertFalse(AirPlayDevice.supportsVideo(features: "0x445F8A00,0x1C340"), "speaker: audio only")
        XCTAssertTrue(AirPlayDevice.supportsVideo(features: ""), "unknown: don't hide it")
    }
}

final class NetworkDoctorTests: XCTestCase {
    func testParsesPingSummary() {
        let out = """
        PING 192.168.1.1 (192.168.1.1): 56 data bytes

        --- 192.168.1.1 ping statistics ---
        8 packets transmitted, 6 packets received, 25.0% packet loss
        round-trip min/avg/max/stddev = 1.912/4.250/9.880/2.101 ms
        """
        let p = NetworkDoctor.parsePing(out)
        XCTAssertEqual(p?.sent, 8); XCTAssertEqual(p?.received, 6)
        XCTAssertEqual(p?.avgMs ?? 0, 4.25, accuracy: 0.001)
        XCTAssertEqual(p?.loss ?? 0, 0.25, accuracy: 0.001)
        XCTAssertNil(NetworkDoctor.parsePing("ping: cannot resolve"))
    }

    private func healthy() -> NetworkDoctor.Input {
        var i = NetworkDoctor.Input(address: "192.168.1.20", gateway: "192.168.1.1")
        i.rssi = -55; i.noise = -92
        i.router = .init(sent: 8, received: 8, avgMs: 3)
        i.internet = .init(sent: 8, received: 8, avgMs: 20)
        i.httpsOK = true; i.dnsOK = true; i.dnsMs = 20; i.signInPage = false
        return i
    }

    func testHealthyNetworkSaysSo() {
        let r = NetworkDoctor.diagnose(healthy())
        XCTAssertEqual(r.findings.map(\.id), ["net.ok"])
    }

    func testFirstBrokenStepIsBlamed() {
        var i = healthy(); i.isUp = false
        XCTAssertEqual(NetworkDoctor.diagnose(i).findings.first?.id, "net.down")
        i = healthy(); i.address = "169.254.3.4"
        XCTAssertEqual(NetworkDoctor.diagnose(i).findings.first?.id, "net.dhcp")
        i = healthy(); i.internet = .init(sent: 8, received: 0, avgMs: nil); i.httpsOK = false
        XCTAssertEqual(NetworkDoctor.diagnose(i).findings.first?.id, "net.internet", "router fine, internet not")
        i = healthy(); i.dnsOK = false
        XCTAssertEqual(NetworkDoctor.diagnose(i).findings.first?.id, "net.dns")
    }

    func testSignInPageIsNotBlamedOnTheProvider() {
        var i = healthy(); i.signInPage = true; i.httpsOK = nil; i.internet = .init(sent: 8, received: 0, avgMs: nil)
        let ids = NetworkDoctor.diagnose(i).findings.map(\.id)
        XCTAssertTrue(ids.contains("net.portal"))
        XCTAssertFalse(ids.contains("net.internet"))
    }

    func testIcmpBlockedButWebWorksIsFine() {
        var i = healthy(); i.internet = .init(sent: 8, received: 0, avgMs: nil)     // some networks block ping
        XCTAssertFalse(NetworkDoctor.diagnose(i).findings.map(\.id).contains("net.internet"))
    }

    func testWeakSignalAndInterference() {
        var i = healthy(); i.rssi = -80; i.noise = -90
        let ids = Set(NetworkDoctor.diagnose(i).findings.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: ["net.signal", "net.noise"]))
    }
}
