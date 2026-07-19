import XCTest

@testable import Clicktion

@MainActor
final class DictationPadViewModelTests: XCTestCase {

    func testAppendFinalOnEmpty() {
        let vm = DictationPadViewModel()
        vm.appendFinal("Hello")
        XCTAssertEqual(vm.committed, "Hello")
        XCTAssertEqual(vm.partial, "")
    }

    func testAppendFinalInsertsSeparatingSpace() {
        let vm = DictationPadViewModel()
        vm.appendFinal("Hello")
        vm.appendFinal("world")
        XCTAssertEqual(vm.committed, "Hello world")
    }

    func testAppendFinalNoDoubleSpace() {
        let vm = DictationPadViewModel()
        vm.committed = "Hello "
        vm.appendFinal("world")
        XCTAssertEqual(vm.committed, "Hello world")
    }

    func testAppendFinalClearsPartial() {
        let vm = DictationPadViewModel()
        vm.setPartial("in progress")
        vm.appendFinal("done")
        XCTAssertEqual(vm.partial, "")
        XCTAssertEqual(vm.committed, "done")
    }

    func testDisplayCombinesCommittedAndPartial() {
        let vm = DictationPadViewModel()
        vm.committed = "Hello"
        vm.setPartial("there")
        XCTAssertEqual(vm.display, "Hello there")
    }

    func testDisplayIsCommittedWhenNoPartial() {
        let vm = DictationPadViewModel()
        vm.committed = "Hello"
        XCTAssertEqual(vm.display, "Hello")
    }

    func testClearResetsEverything() {
        let vm = DictationPadViewModel()
        vm.committed = "Hello"
        vm.setPartial("there")
        vm.clear()
        XCTAssertEqual(vm.committed, "")
        XCTAssertEqual(vm.partial, "")
    }

    func testShowAndClearError() {
        let vm = DictationPadViewModel()
        vm.showError("boom")
        XCTAssertEqual(vm.error, "boom")
        vm.clearError()
        XCTAssertNil(vm.error)
    }
}
