import XCTest

@testable import Clicktion

@MainActor
final class AppStateTests: XCTestCase {

    func testLanguageHints() {
        let state = AppState.shared
        let original = state.parakeetLanguage
        defer { state.parakeetLanguage = original }

        state.parakeetLanguage = "auto"
        XCTAssertEqual(state.parakeetLanguageHints, ["nl", "en"])

        state.parakeetLanguage = "nl"
        XCTAssertEqual(state.parakeetLanguageHints, ["nl"])

        state.parakeetLanguage = "en"
        XCTAssertEqual(state.parakeetLanguageHints, ["en"])

        // Any legacy/unknown value falls back to bilingual auto.
        state.parakeetLanguage = "system"
        XCTAssertEqual(state.parakeetLanguageHints, ["nl", "en"])
    }

    func testDictationHotKeyReflectsStoredCodeAndModifiers() {
        let state = AppState.shared
        let origCode = state.dictationHotKeyCode
        let origMods = state.dictationHotKeyModifiers
        defer {
            state.dictationHotKeyCode = origCode
            state.dictationHotKeyModifiers = origMods
        }

        state.dictationHotKeyCode = 2          // D
        state.dictationHotKeyModifiers = 0
        XCTAssertEqual(state.dictationHotKey.keyCode, 2)
        XCTAssertEqual(state.dictationHotKey.modifiers, 0)
    }
}
