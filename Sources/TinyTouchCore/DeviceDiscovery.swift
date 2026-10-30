import Foundation
import IOKit
import IOKit.serial

public struct DevicePort: Equatable, Hashable {
    public let path: String
    public let serialNumber: String?
    public let productName: String?
    public let vendorID: Int?

    /// Stable identity used for Keychain accounts and pairing.
    public var deviceID: String { serialNumber ?? path }

    /// ESP32-S3 ROM download mode: "USB JTAG/serial debug unit" with the MAC as serial number.
    public var isROMBootloader: Bool {
        if let productName, productName.localizedCaseInsensitiveContains("JTAG") { return true }
        return serialNumber?.contains(":") == true
    }

    public var looksLikeTinyTouch: Bool {
        if let productName, productName.localizedCaseInsensitiveContains("tinytouch") { return true }
        if let serialNumber, serialNumber.hasPrefix("TT-") { return true }
        return false
    }
}

public enum DeviceDiscovery {
    public static let espressifVendorID = 0x303A

    /// All USB CDC serial ports, tinyTouch devices first.
    public static func ports() -> [DevicePort] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) as NSMutableDictionary? else { return [] }
        matching[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [DevicePort] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = property(service, kIOCalloutDeviceKey, searchParents: false) as? String,
                  path.contains("usbmodem") else { continue }
            result.append(DevicePort(
                path: path,
                serialNumber: property(service, "USB Serial Number") as? String,
                productName: property(service, "USB Product Name") as? String,
                vendorID: (property(service, "idVendor") as? NSNumber)?.intValue
            ))
        }
        return result.sorted { lhs, rhs in
            if lhs.looksLikeTinyTouch != rhs.looksLikeTinyTouch { return lhs.looksLikeTinyTouch }
            return lhs.path < rhs.path
        }
    }

    /// The first port that is clearly a tinyTouch, or else the first Espressif CDC port.
    public static func tinyTouchPort() -> DevicePort? {
        let all = ports()
        return all.first(where: \.looksLikeTinyTouch)
            ?? all.first { $0.vendorID == espressifVendorID && !$0.isROMBootloader }
    }

    private static func property(_ service: io_object_t, _ key: String, searchParents: Bool = true) -> Any? {
        if !searchParents {
            return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        return IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault, options)
    }
}
