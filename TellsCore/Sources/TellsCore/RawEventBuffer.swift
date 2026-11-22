import Foundation

/// Raw samples in memory only (hard rule 1, SPEC.md 4.1). One ring for each sensor.
/// A full ring writes over its oldest sample.
public actor RawEventBuffer {
    // DEFAULT: D-033
    public static let defaultCapacity = 20_000

    private struct Ring {
        var storage: [SensorSample] = []
        var oldest = 0

        mutating func append(_ sample: SensorSample, capacity: Int) {
            if storage.count < capacity {
                storage.append(sample)
            } else {
                storage[oldest] = sample
                oldest = (oldest + 1) % capacity
            }
        }

        var inArrivalOrder: [SensorSample] {
            Array(storage[oldest...] + storage[..<oldest])
        }
    }

    private let capacity: Int
    private var rings: [SensorID: Ring] = [:]

    public init(capacity: Int = RawEventBuffer.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public func append(_ sample: SensorSample) {
        rings[sample.sensor, default: Ring()].append(sample, capacity: capacity)
    }

    public func count(for sensor: SensorID) -> Int {
        rings[sensor]?.storage.count ?? 0
    }

    /// The samples with `window.start <= time < window.end`, in time order.
    public func samples(for sensor: SensorID, in window: DateInterval) -> [SensorSample] {
        guard let ring = rings[sensor] else { return [] }
        return ring.inArrivalOrder
            .filter { $0.time >= window.start && $0.time < window.end }
            .enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map(\.element)
    }

    /// Deletes the samples of `sensor` with `time < end`.
    public func removeSamples(for sensor: SensorID, before end: Date) {
        guard let ring = rings[sensor] else { return }
        var kept = Ring()
        for sample in ring.inArrivalOrder where sample.time >= end {
            kept.append(sample, capacity: capacity)
        }
        rings[sensor] = kept
    }

    public func removeAll() {
        rings.removeAll()
    }
}
