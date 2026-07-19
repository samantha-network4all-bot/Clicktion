import XCTest

@testable import Clicktion

final class AudioSampleBufferTests: XCTestCase {

    func testAppendAndCount() {
        let buffer = AudioSampleBuffer()
        XCTAssertEqual(buffer.count, 0)
        buffer.append([1, 2, 3])
        buffer.append([4, 5])
        XCTAssertEqual(buffer.count, 5)
    }

    func testDrainReturnsAllAndClears() {
        let buffer = AudioSampleBuffer()
        buffer.append([1, 2, 3])
        XCTAssertEqual(buffer.drain(), [1, 2, 3])
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.drain(), [])
    }

    func testSnapshotDoesNotClear() {
        let buffer = AudioSampleBuffer()
        buffer.append([1, 2, 3])
        XCTAssertEqual(buffer.snapshot(), [1, 2, 3])
        XCTAssertEqual(buffer.count, 3)
    }

    func testTakeReturnsExactChunkAndRemainder() {
        let buffer = AudioSampleBuffer()
        buffer.append([1, 2, 3, 4, 5])
        XCTAssertEqual(buffer.take(2), [1, 2])
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.snapshot(), [3, 4, 5])
    }

    func testTakeReturnsNilWhenInsufficient() {
        let buffer = AudioSampleBuffer()
        buffer.append([1, 2])
        XCTAssertNil(buffer.take(3))
        XCTAssertEqual(buffer.count, 2)   // untouched
    }

    func testReset() {
        let buffer = AudioSampleBuffer()
        buffer.append([1, 2, 3])
        buffer.reset()
        XCTAssertEqual(buffer.count, 0)
    }
}
