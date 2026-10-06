import CoreGraphics
import XCTest

final class LockTapPolicyTests: XCTestCase {

    private let none: CGEventFlags = []

    // MARK: - Keys

    func testPlainKeyDownIsSwallowed() {
        let (decision, _) = LockTapPolicy.decide(
            type: .keyDown, flags: none, keyCode: 0, state: .init(delivered: none)
        )
        XCTAssertEqual(decision, .swallow)
    }

    func testForceQuitEscapePassesAndPairsItsKeyUp() {
        let flags: CGEventFlags = [.maskCommand, .maskAlternate]
        let (down, afterDown) = LockTapPolicy.decide(
            type: .keyDown, flags: flags, keyCode: LockTapPolicy.escapeKeyCode,
            state: .init(delivered: none)
        )
        XCTAssertEqual(down, .pass)
        XCTAssertTrue(afterDown.escapeDown)

        // The user may have released Cmd first; the up must still pass.
        let (up, afterUp) = LockTapPolicy.decide(
            type: .keyUp, flags: none, keyCode: LockTapPolicy.escapeKeyCode, state: afterDown
        )
        XCTAssertEqual(up, .pass)
        XCTAssertFalse(afterUp.escapeDown)
    }

    func testEscapeWithoutCmdOptIsSwallowed() {
        let (decision, _) = LockTapPolicy.decide(
            type: .keyDown, flags: [.maskCommand], keyCode: LockTapPolicy.escapeKeyCode,
            state: .init(delivered: none)
        )
        XCTAssertEqual(decision, .swallow)
    }

    func testCmdOptCtrlEscapeIsSwallowed() {
        let (decision, _) = LockTapPolicy.decide(
            type: .keyDown, flags: [.maskCommand, .maskAlternate, .maskControl],
            keyCode: LockTapPolicy.escapeKeyCode, state: .init(delivered: none)
        )
        XCTAssertEqual(decision, .swallow)
    }

    func testStrayEscapeKeyUpIsSwallowed() {
        let (decision, _) = LockTapPolicy.decide(
            type: .keyUp, flags: none, keyCode: LockTapPolicy.escapeKeyCode,
            state: .init(delivered: none)
        )
        XCTAssertEqual(decision, .swallow)
    }

    // MARK: - Modifiers

    func testModifierPressIsSwallowed() {
        let (decision, state) = LockTapPolicy.decide(
            type: .flagsChanged, flags: [.maskShift], keyCode: 56, state: .init(delivered: none)
        )
        XCTAssertEqual(decision, .swallow)
        XCTAssertEqual(state.delivered, none)
    }

    func testModifierReleaseOfDeliveredModifierPasses() {
        let (decision, state) = LockTapPolicy.decide(
            type: .flagsChanged, flags: none, keyCode: 56,
            state: .init(delivered: [.maskShift])
        )
        XCTAssertEqual(decision, .pass)
        XCTAssertEqual(state.delivered, none)
    }

    func testNonModifierEventTypesPass() {
        let (decision, _) = LockTapPolicy.decide(
            type: .mouseMoved, flags: none, keyCode: 0, state: .init(delivered: none)
        )
        XCTAssertEqual(decision, .pass)
    }

    // MARK: - Media keys

    private func data1(keyType: Int64, state: Int64, repeatBit: Int64 = 0) -> Int64 {
        (keyType << 16) | (state << 8) | repeatBit
    }

    func testMediaKeyPressIsSwallowed() {
        let decision = LockTapPolicy.decideSystemDefined(
            subtypeA: 8, subtypeB: 8, data1: data1(keyType: 0, state: 0x0A)
        )
        XCTAssertEqual(decision, .swallow)
    }

    func testMediaKeyReleasePasses() {
        let decision = LockTapPolicy.decideSystemDefined(
            subtypeA: 8, subtypeB: 8, data1: data1(keyType: 0, state: 0x0B)
        )
        XCTAssertEqual(decision, .pass)
    }

    func testPowerAndCapsLockPass() {
        for keyType in [LockTapPolicy.powerKeyType, LockTapPolicy.capsLockKeyType] {
            let decision = LockTapPolicy.decideSystemDefined(
                subtypeA: 8, subtypeB: 8, data1: data1(keyType: keyType, state: 0x0A)
            )
            XCTAssertEqual(decision, .pass, "key type \(keyType)")
        }
    }

    func testOtherSubtypesPassWithoutReadingData1() {
        // Reading field 149 on the wrong subtype aborts the process, so data1
        // must never be evaluated unless both subtypes say 8.
        for (a, b) in [(7, 7), (6, 6), (9, 9), (8, 7), (7, 8)] as [(Int64, Int64)] {
            let decision = LockTapPolicy.decideSystemDefined(
                subtypeA: a, subtypeB: b,
                data1: { XCTFail("data1 read for subtypes \(a)/\(b)"); return 0 }()
            )
            XCTAssertEqual(decision, .pass)
        }
    }

    func testMalformedData1Passes() {
        XCTAssertEqual(
            LockTapPolicy.decideSystemDefined(subtypeA: 8, subtypeB: 8, data1: -1), .pass
        )
        XCTAssertEqual(
            LockTapPolicy.decideSystemDefined(subtypeA: 8, subtypeB: 8, data1: 0x1_0000_0000), .pass
        )
        // Stray low bits beyond the repeat bit.
        XCTAssertEqual(
            LockTapPolicy.decideSystemDefined(
                subtypeA: 8, subtypeB: 8, data1: data1(keyType: 0, state: 0x0A, repeatBit: 2)
            ),
            .pass
        )
    }

    func testMaskCoversKeysButNoMouseEvents() {
        for type in [CGEventType.keyDown, .keyUp, .flagsChanged] {
            XCTAssertNotEqual(LockTapPolicy.mask & (1 << type.rawValue), 0)
        }
        for type in [CGEventType.leftMouseDown, .rightMouseDown, .mouseMoved, .scrollWheel] {
            XCTAssertEqual(LockTapPolicy.mask & (1 << type.rawValue), 0)
        }
    }
}
