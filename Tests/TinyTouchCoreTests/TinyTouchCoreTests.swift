import XCTest
@testable import TinyTouchCore

final class PairingCryptoTests: XCTestCase {
    // Reference vectors computed with the upstream Python helper's algorithm (HMAC-SHA256 + AES-256-CTR).
    let key = Data((0..<32).map { UInt8($0) })
    let nonce = "00112233445566778899aabbccddeeff"
    let keyID = "630dcd2966c43366"
    let eventMAC = "19100e0ca9fdf7567087be51b03550534bb72ccf069ae5d4b02f53d0a4a596d1"

    func testKeyID() {
        XCTAssertEqual(PairingCrypto.keyID(key), keyID)
    }

    func testParsesAuthenticatedEV2AmongOtherHosts() throws {
        let line = "EV2 \(nonce) 7 2 150 aaaaaaaaaaaaaaaa:\(String(repeating: "0", count: 64)) \(keyID):\(eventMAC)"
        let event = try XCTUnwrap(PairingCrypto.parseEvent(line, pairingKey: key))
        XCTAssertEqual(event.slot, 2)
        XCTAssertEqual(event.counter, 7)
        XCTAssertEqual(event.keyID, keyID)
    }

    func testRejectsForgedEvent() {
        let forged = "EV2 \(nonce) 7 3 150 \(keyID):\(eventMAC)"
        XCTAssertNil(PairingCrypto.parseEvent(forged, pairingKey: key))
    }

    func testReplyMatchesReference() throws {
        let line = "EV2 \(nonce) 7 2 150 \(keyID):\(eventMAC)"
        let event = try XCTUnwrap(PairingCrypto.parseEvent(line, pairingKey: key))
        let reply = try PairingCrypto.reply(to: event, password: Data("hunter2".utf8), pairingKey: key, iv: Data(count: 16))
        XCTAssertEqual(reply, "PW2 \(keyID) \(nonce) \(String(repeating: "0", count: 32)) 720b2c398606a6 "
            + "c21cc4b4c5acd18e9367893c61b59634e5c0c9cbfc3b42a28a7b13c9e4b90972")
    }

    func testResponderBlocksReplay() {
        let responder = TouchResponder()
        let line = "EV2 \(nonce) 7 2 150 \(keyID):\(eventMAC)"
        let first = responder.handle(line: line, pairingKey: key, password: { _ in Data("pw".utf8) }, allow: { nil })
        guard case .replied = first else { return XCTFail("expected reply") }
        XCTAssertEqual(responder.handle(line: line, pairingKey: key, password: { _ in Data("pw".utf8) }, allow: { nil }),
                       .ignored("sự kiện lặp lại (replay)"))
    }
}

final class DeviceProtocolTests: XCTestCase {
    func testStatusLineFromMrOldFirmware() {
        let status = DeviceStatus(line: "OK STATUS firmware=mroldtouch firmware_version=1.1.7 protocol=2 mode=hid post_key=enter post_key_delay=50 wake_delay=0 sensor=ok fingerprints=2 keys=unconfigured hid_key=configured hid_hosts=2")
        XCTAssertEqual(status.mode, .hid)
        XCTAssertEqual(status.firmwareVersion, "1.1.7")
        XCTAssertEqual(status.postKeyDelay, 50)
        XCTAssertEqual(status.wakeDelay, 0)
        XCTAssertEqual(status.fingerprints, 2)
        XCTAssertEqual(status.hidHosts, 2)
    }

    func testSlotStatus() {
        let slots = SlotInfo.parse("OK SLOT_STATUS e1=1 e2=1 e3=0 e4=0 e5=0 p1=0 p2=1 p3=0 p4=0 p5=0", fingerprints: 2)
        XCTAssertEqual(slots.filter(\.enrolled).map(\.id), [1, 2])
        XCTAssertEqual(slots.filter(\.hasChipPassword).map(\.id), [2])
    }

    func testPostKeyNormalize() {
        XCTAssertEqual(PostKey.normalize("Enter, Space"), "enter,space")
        XCTAssertEqual(PostKey.normalize("none,none"), "none")
        XCTAssertEqual(PostKey.normalize("tab,none,enter"), "tab,enter")
        XCTAssertNil(PostKey.normalize("f1"))
        XCTAssertNil(PostKey.normalize("enter,enter,enter,enter"))
    }

    func testTouchPrompts() {
        XCTAssertEqual(TouchPrompt.parse("PROMPT TOUCH 3 6"), TouchPrompt(kind: .touch, step: 3, total: 6))
        XCTAssertEqual(TouchPrompt.parse("PROMPT LIFT 2"), TouchPrompt(kind: .lift, step: 2, total: nil))
        XCTAssertEqual(TouchPrompt.parse("PROMPT TOUCH_AGAIN"), TouchPrompt(kind: .touch, step: 2, total: 2))
        XCTAssertNil(TouchPrompt.parse("OK STATUS"))
    }

    func testRedactsSecrets() {
        XCTAssertEqual(DeviceClient.redact("SET_SLOT_PASSWORD 2 my secret"), "SET_SLOT_PASSWORD 2 ••••••")
        XCTAssertEqual(DeviceClient.redact("HID_KEY_ADD abcd 0011"), "HID_KEY_ADD abcd ••••••")
        XCTAssertEqual(DeviceClient.redact("STATUS"), "STATUS")
    }

    func testChipMACFromSerial() {
        XCTAssertEqual(DeviceStatus.chipMAC(fromSerial: "TT-90DA72470794"), "90DA72470794")
        XCTAssertNil(DeviceStatus.chipMAC(fromSerial: "0133000001"))
    }

    func testTerminalLines() {
        XCTAssertTrue(DeviceClient.isTerminal("OK CONFIG_UNLOCK fingerprint seconds=120"))
        XCTAssertTrue(DeviceClient.isTerminal("PASSKEY_CLEAR_OK"))
        XCTAssertTrue(DeviceClient.isTerminal("{\"passkeys\":[]}"))
        XCTAssertFalse(DeviceClient.isTerminal("PROMPT TOUCH 1 2"))
    }
}

final class ESPFlasherTests: XCTestCase {
    func testSlipRoundTrip() {
        let raw: [UInt8] = [0x01, 0xC0, 0x02, 0xDB, 0x03]
        let encoded = ESPFlasher.slipEncode(raw)
        XCTAssertEqual(encoded, [0xC0, 0x01, 0xDB, 0xDC, 0x02, 0xDB, 0xDD, 0x03, 0xC0])
        XCTAssertEqual(ESPFlasher.slipDecode(Array(encoded.dropFirst().dropLast())), raw)
    }

    func testChecksumMatchesEsptool() {
        // esptool: checksum = 0xEF ^ every data byte
        XCTAssertEqual(ESPFlasher.checksum([]), 0xEF)
        XCTAssertEqual(ESPFlasher.checksum([0xFF, 0x01]), 0xEF ^ 0xFF ^ 0x01)
    }

    func testSecurityInfoFlags() {
        let info = ESPFlasher.SecurityInfo(flags: 0b101, flashCryptCount: 0b1, chipID: 9)
        XCTAssertTrue(info.flashEncrypted)
        XCTAssertTrue(info.secureBoot)
        XCTAssertTrue(info.secureDownloadMode)
        XCTAssertFalse(ESPFlasher.SecurityInfo(flags: 0, flashCryptCount: 0b11, chipID: 9).flashEncrypted)
    }
}
