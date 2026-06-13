import XCTest
import CryptoKit
@testable import GazeFocusShell
@testable import GazeFocusCore

// U13: encrypted model codec (the testable core of the store; the Keychain/file
// glue is exercised on-device).
final class ModelCodecTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)
    private let state = DwellModelState(threshold: 0.62, graduated: true)
    private let ctx = "com.gazefocus#v1"

    func testRoundTrip() throws {
        let blob = try ModelCodec.seal(state, key: key, context: ctx)
        XCTAssertEqual(try ModelCodec.open(blob, key: key, context: ctx), state)
    }

    func testTamperedBlobFails() throws {
        var blob = try ModelCodec.seal(state, key: key, context: ctx)
        blob[blob.count - 1] ^= 0xFF                      // flip a byte in the tag/ciphertext
        XCTAssertThrowsError(try ModelCodec.open(blob, key: key, context: ctx))
    }

    func testWrongContextFails() throws {
        let blob = try ModelCodec.seal(state, key: key, context: ctx)
        XCTAssertThrowsError(try ModelCodec.open(blob, key: key, context: "com.gazefocus#v2"))
    }

    func testWrongKeyFails() throws {
        let blob = try ModelCodec.seal(state, key: key, context: ctx)
        XCTAssertThrowsError(try ModelCodec.open(blob, key: SymmetricKey(size: .bits256), context: ctx))
    }
}

// U12: system-event → lifecycle-event mapping.
final class SystemEventMappingTests: XCTestCase {
    func testKnownNotifications() {
        XCTAssertEqual(SystemEventMapping.event(forNotificationNamed: "NSWorkspaceWillSleepNotification"), .system(.sleep))
        XCTAssertEqual(SystemEventMapping.event(forNotificationNamed: "com.apple.screenIsLocked"), .system(.lock))
        XCTAssertEqual(SystemEventMapping.event(forNotificationNamed: "com.apple.screenIsUnlocked"), .system(.unlock))
        XCTAssertEqual(SystemEventMapping.event(forNotificationNamed: "NSWorkspaceDidWakeNotification"), .system(.wake))
        XCTAssertEqual(SystemEventMapping.event(forNotificationNamed: "NSWorkspaceActiveSpaceDidChangeNotification"), .system(.spaceChanged))
    }

    func testUnknownNotificationMapsToNil() {
        XCTAssertNil(SystemEventMapping.event(forNotificationNamed: "SomeUnrelatedNotification"))
    }
}
