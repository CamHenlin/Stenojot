import XCTest
@testable import TranscriberCore

final class EchoCancellerTests: XCTestCase {
    func testZeroReferenceLeavesTheMicrophoneIntact() {
        let canceller = EchoCanceller(filterLength: 32, stepSize: 0.2)
        let microphone: [Int16] = [1000, -2000, 3000, 0, 500, -50]
        let reference = [Int16](repeating: 0, count: microphone.count)
        let output = canceller.process(microphone: microphone, reference: reference)
        for (input, cleaned) in zip(microphone, output) {
            XCTAssertLessThanOrEqual(abs(Int(cleaned) - Int(input)), 1)
        }
    }

    func testDelayedReferenceIsCancelled() {
        let canceller = EchoCanceller(filterLength: 64, stepSize: 0.5)
        let count = 16_000
        let delay = 8
        var reference = [Int16](repeating: 0, count: count)
        var microphone = [Int16](repeating: 0, count: count)
        var state: UInt32 = 0x12345678
        for index in 0..<count {
            state = state &* 1664525 &+ 1013904223
            let sample = Int16(Int32(state % 16001) - 8000)
            reference[index] = sample
            if index >= delay {
                microphone[index] = reference[index - delay] / 2
            }
        }

        let output = canceller.process(microphone: microphone, reference: reference)
        let tail = count - 2000
        let cleaned = rms(Array(output[tail...]))
        let original = rms(Array(microphone[tail...]))
        XCTAssertLessThan(cleaned, original * 0.2)
    }

    func testLocalVoiceSurvivesCancellation() {
        let canceller = EchoCanceller(filterLength: 64, stepSize: 0.4)
        let count = 16_000
        let delay = 8
        var reference = [Int16](repeating: 0, count: count)
        var microphone = [Int16](repeating: 0, count: count)
        var state: UInt32 = 0x89ABCDEF
        for index in 0..<count {
            state = state &* 1664525 &+ 1013904223
            let sample = Int16(Int32(state % 8001) - 4000)
            reference[index] = sample
            let echo: Int16 = index >= delay ? reference[index - delay] / 2 : 0
            let voice: Int16 = (index / 20).isMultiple(of: 2) ? 12000 : -12000
            microphone[index] = saturatingAdd(echo, voice)
        }

        let output = canceller.process(microphone: microphone, reference: reference)
        let cleaned = rms(Array(output.suffix(2000)))
        XCTAssertGreaterThan(cleaned, 5000)
    }

    private func rms(_ samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            let value = Float(sample)
            sum += value * value
        }
        return (sum / Float(samples.count)).squareRoot()
    }

    private func saturatingAdd(_ lhs: Int16, _ rhs: Int16) -> Int16 {
        let sum = Int32(lhs) + Int32(rhs)
        return Int16(max(-32768, min(32767, sum)))
    }
}

final class SpeakerMixerTests: XCTestCase {
    func testCallerFramesPassThrough() {
        let mixer = SpeakerMixer(
            canceller: EchoCanceller(filterLength: 32),
            referenceLead: 0,
            holdSeconds: 0
        )
        var frames: [(Speaker, [Int16])] = []
        mixer.onFrame = { speaker, samples in
            frames.append((speaker, samples))
        }
        let caller = [Int16](repeating: 1500, count: 480)
        mixer.append(caller, from: .caller, at: 0)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].0, .caller)
        XCTAssertEqual(frames[0].1, caller)
    }

    func testMicrophoneWithoutCallAudioIsYou() {
        let mixer = SpeakerMixer(
            canceller: EchoCanceller(filterLength: 32),
            referenceLead: 0,
            holdSeconds: 0
        )
        var frames: [(Speaker, [Int16])] = []
        mixer.onFrame = { speaker, samples in
            frames.append((speaker, samples))
        }
        let you = [Int16](repeating: 2000, count: SpeakerMixer.frameSamples)
        mixer.append(you, from: .you, at: 0)
        XCTAssertEqual(frames.map(\.0), [.you])
        for sample in frames[0].1 {
            XCTAssertLessThanOrEqual(abs(Int(sample) - 2000), 1)
        }
    }

    func testPureEchoIsSilencedAfterConvergence() {
        let mixer = SpeakerMixer(
            canceller: EchoCanceller(filterLength: 64, stepSize: 0.5),
            referenceLead: 0,
            holdSeconds: 0
        )
        var youFrames: [[Int16]] = []
        mixer.onFrame = { speaker, samples in
            if speaker == .you {
                youFrames.append(samples)
            }
        }

        let frameCount = 40
        let frame = SpeakerMixer.frameSamples
        var reference = [Int16](repeating: 0, count: frameCount * frame)
        var microphone = [Int16](repeating: 0, count: reference.count)
        var state: UInt32 = 0x2468
        for index in 0..<reference.count {
            state = state &* 1664525 &+ 1013904223
            reference[index] = Int16(Int32(state % 16001) - 8000)
            if index >= 8 {
                microphone[index] = reference[index - 8] / 2
            }
        }
        mixer.append(reference, from: .caller, at: 0)
        mixer.append(microphone, from: .you, at: 0)

        let tail = youFrames.suffix(4).flatMap { $0 }
        XCTAssertFalse(tail.isEmpty)
        XCTAssertLessThan(rms(tail), 400)
    }

    private func rms(_ samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            let value = Float(sample)
            sum += value * value
        }
        return (sum / Float(samples.count)).squareRoot()
    }
}
