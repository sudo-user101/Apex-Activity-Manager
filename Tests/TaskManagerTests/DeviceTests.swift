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
        XCTAssertEqual(keys, ["cpu", "memory", "disk", "disk:disk6", "disk:disk8", "network", "net:en7", "gpu", "battery", "sensors"])
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
}
