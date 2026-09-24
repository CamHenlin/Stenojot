import Foundation

/// Joins microphone and call-audio clocks, cancels speaker bleed, and emits
/// 30 ms frames tagged with who was speaking.
public final class SpeakerMixer: @unchecked Sendable {
    public static let frameSamples = 480
    public static let sampleRate = 16_000.0

    public var onFrame: ((Speaker, [Int16]) -> Void)?

    private let canceller: EchoCanceller
    private let referenceLead: TimeInterval
    private let holdSeconds: TimeInterval
    private let lock = NSLock()

    private var callerTimeline = SampleTimeline(sampleRate: sampleRate)
    private var callerPending: [Int16] = []
    private var youPending: [Int16] = []
    private var youPendingTime: TimeInterval?
    private var youQueue: [(time: TimeInterval, samples: [Int16])] = []
    private var latestTime: TimeInterval = 0

    public init(
        canceller: EchoCanceller = EchoCanceller(),
        referenceLead: TimeInterval = 0.15,
        holdSeconds: TimeInterval = 0.25
    ) {
        self.canceller = canceller
        self.referenceLead = referenceLead
        self.holdSeconds = holdSeconds
    }

    public func reset() {
        lock.lock()
        callerTimeline = SampleTimeline(sampleRate: Self.sampleRate)
        callerPending.removeAll(keepingCapacity: false)
        youPending.removeAll(keepingCapacity: false)
        youPendingTime = nil
        youQueue.removeAll(keepingCapacity: false)
        latestTime = 0
        canceller.reset()
        lock.unlock()
    }

    public func append(_ data: Data, from speaker: Speaker, at time: TimeInterval) {
        let samples: [Int16] = data.withUnsafeBytes { raw in
            let bound = raw.bindMemory(to: Int16.self)
            return Array(bound)
        }
        append(samples, from: speaker, at: time)
    }

    public func append(_ samples: [Int16], from speaker: Speaker, at time: TimeInterval) {
        guard !samples.isEmpty else { return }
        var ready: [(Speaker, [Int16])] = []
        lock.lock()
        let end = time + Double(samples.count) / Self.sampleRate
        if end > latestTime {
            latestTime = end
        }
        if speaker == .caller {
            callerTimeline.append(samples, at: time)
            callerTimeline.cap(maxDuration: 5)
            callerPending.append(contentsOf: samples)
            ready.append(contentsOf: takeFrames(from: &callerPending, speaker: .caller))
        } else {
            if youPending.isEmpty {
                youPendingTime = time
            }
            youPending.append(contentsOf: samples)
            let frameDuration = Double(Self.frameSamples) / Self.sampleRate
            while youPending.count >= Self.frameSamples {
                let frame = Array(youPending.prefix(Self.frameSamples))
                youPending.removeFirst(Self.frameSamples)
                let start = youPendingTime ?? time
                youPendingTime = start + frameDuration
                youQueue.append((start, frame))
            }
        }
        ready.append(contentsOf: drainLocked())
        lock.unlock()
        for frame in ready {
            onFrame?(frame.0, frame.1)
        }
    }

    private func drainLocked() -> [(Speaker, [Int16])] {
        let frameDuration = Double(Self.frameSamples) / Self.sampleRate
        var ready: [(Speaker, [Int16])] = []
        while let next = youQueue.first {
            let refStart = next.time + referenceLead
            let refEnd = refStart + frameDuration
            let reference: [Int16]
            if let aligned = callerTimeline.slice(from: refStart, count: Self.frameSamples) {
                reference = aligned
            } else if latestTime - refEnd >= holdSeconds {
                reference = callerTimeline.zeroFilledSlice(from: refStart, count: Self.frameSamples)
            } else {
                break
            }
            youQueue.removeFirst()
            ready.append((.you, cleaned(next.samples, reference: reference)))
            callerTimeline.trim(before: refStart - 0.05)
        }
        return ready
    }

    private func cleaned(_ microphone: [Int16], reference: [Int16]) -> [Int16] {
        let output = canceller.process(microphone: microphone, reference: reference)
        if ResidualEcho.isLeftover(microphone: microphone, cleaned: output, reference: reference) {
            return [Int16](repeating: 0, count: output.count)
        }
        return output
    }

    private func takeFrames(from pending: inout [Int16], speaker: Speaker) -> [(Speaker, [Int16])] {
        var ready: [(Speaker, [Int16])] = []
        while pending.count >= Self.frameSamples {
            ready.append((speaker, Array(pending.prefix(Self.frameSamples))))
            pending.removeFirst(Self.frameSamples)
        }
        return ready
    }
}

enum ResidualEcho {
    /// True when cancellation removed the microphone energy and no local voice remains.
    static func isLeftover(microphone: [Int16], cleaned: [Int16], reference: [Int16]) -> Bool {
        let mic = rms(microphone)
        let clean = rms(cleaned)
        let ref = rms(reference)
        if ref < 400 || mic < 300 { return false }
        if clean > 700 { return false }
        return clean < mic * 0.4
    }

    private static func rms(_ samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            let value = Float(sample)
            sum += value * value
        }
        return (sum / Float(samples.count)).squareRoot()
    }
}

struct SampleTimeline {
    let sampleRate: Double
    private var origin: TimeInterval?
    private var samples: [Int16] = []

    var end: TimeInterval? {
        guard let origin else { return nil }
        return origin + Double(samples.count) / sampleRate
    }

    mutating func append(_ incoming: [Int16], at time: TimeInterval) {
        guard !incoming.isEmpty else { return }
        guard let origin else {
            self.origin = time
            samples = incoming
            return
        }
        let startIndex = Int(((time - origin) * sampleRate).rounded())
        if startIndex < 0 {
            return
        }
        if startIndex > samples.count {
            let gap = startIndex - samples.count
            if gap > Int(sampleRate) {
                self.origin = time
                samples = incoming
                return
            }
            samples.append(contentsOf: repeatElement(0, count: gap))
            samples.append(contentsOf: incoming)
            return
        }
        for (offset, sample) in incoming.enumerated() {
            let index = startIndex + offset
            if index < samples.count {
                samples[index] = sample
            } else {
                samples.append(sample)
            }
        }
    }

    func slice(from time: TimeInterval, count: Int) -> [Int16]? {
        guard let origin, count > 0 else { return nil }
        let startIndex = Int(((time - origin) * sampleRate).rounded())
        let endIndex = startIndex + count
        guard startIndex >= 0, endIndex <= samples.count else { return nil }
        return Array(samples[startIndex..<endIndex])
    }

    func zeroFilledSlice(from time: TimeInterval, count: Int) -> [Int16] {
        guard let origin, count > 0 else { return Array(repeating: 0, count: count) }
        var result = [Int16](repeating: 0, count: count)
        let startIndex = Int(((time - origin) * sampleRate).rounded())
        for offset in 0..<count {
            let index = startIndex + offset
            if index >= 0, index < samples.count {
                result[offset] = samples[index]
            }
        }
        return result
    }

    mutating func trim(before time: TimeInterval) {
        guard let origin else { return }
        let index = Int(((time - origin) * sampleRate).rounded())
        guard index > 0 else { return }
        let drop = min(index, samples.count)
        samples.removeFirst(drop)
        self.origin = origin + Double(drop) / sampleRate
    }

    mutating func cap(maxDuration: TimeInterval) {
        guard let end else { return }
        trim(before: end - maxDuration)
    }
}
