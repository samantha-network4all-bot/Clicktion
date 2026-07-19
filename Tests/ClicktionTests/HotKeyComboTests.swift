import Carbon
import XCTest

@testable import Clicktion

final class HotKeyComboTests: XCTestCase {

    func testDefaultIsOptionSpace() {
        let combo = HotKeyCombo.defaultDictation
        XCTAssertEqual(combo.keyCode, 49)
        XCTAssertEqual(combo.modifiers, UInt32(optionKey))
        XCTAssertEqual(combo.displayString, "⌥Space")
    }

    func testKeyNames() {
        XCTAssertEqual(HotKeyCombo.keyName(49), "Space")
        XCTAssertEqual(HotKeyCombo.keyName(0), "A")
        XCTAssertEqual(HotKeyCombo.keyName(124), "→")
        XCTAssertEqual(HotKeyCombo.keyName(36), "Return")
        XCTAssertEqual(HotKeyCombo.keyName(9), "V")
    }

    func testUnknownKeyFallsBack() {
        XCTAssertEqual(HotKeyCombo.keyName(200), "Key200")
    }

    func testModifierSymbolOrder() {
        let all = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        let combo = HotKeyCombo(keyCode: 2, modifiers: all)   // D
        XCTAssertEqual(combo.displayString, "⌃⌥⇧⌘D")
    }

    func testCarbonModifierConversion() {
        XCTAssertEqual(HotKeyCombo.carbonModifiers([.option]), UInt32(optionKey))
        XCTAssertEqual(HotKeyCombo.carbonModifiers([.command, .shift]),
                       UInt32(cmdKey) | UInt32(shiftKey))
        XCTAssertEqual(HotKeyCombo.carbonModifiers([]), 0)
    }
}
