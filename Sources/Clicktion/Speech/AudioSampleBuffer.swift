import os

/// Lock-protected sample store. The audio tap appends from a real-time thread
/// while the main actor drains it, so all access is serialized behind a lock.
final class AudioSampleBuffer: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var samples = [Float]()

    var count: Int { lock.withLock { samples.count } }

    /// A copy of the accumulated samples without clearing them (for live partials).
    func snapshot() -> [Float] { lock.withLock { samples } }

    func append(_ new: [Float]) {
        lock.withLock { samples.append(contentsOf: new) }
    }

    func drain() -> [Float] {
        lock.withLock {
            let out = samples
            samples.removeAll(keepingCapacity: true)
            return out
        }
    }

    /// Removes and returns exactly `n` samples, or nil if fewer are available
    /// (used to feed the VAD in fixed-size chunks).
    func take(_ n: Int) -> [Float]? {
        lock.withLock {
            guard samples.count >= n else { return nil }
            let chunk = Array(samples.prefix(n))
            samples.removeFirst(n)
            return chunk
        }
    }

    func reset() {
        lock.withLock { samples.removeAll(keepingCapacity: true) }
    }
}

/// Tracks the previous silence state. Touched only from the serial audio-tap
/// thread, so no locking is needed; the class exists so the tap closure can
/// mutate it by reference.
final class SilenceState: @unchecked Sendable {
    var wasSilence = false
}
