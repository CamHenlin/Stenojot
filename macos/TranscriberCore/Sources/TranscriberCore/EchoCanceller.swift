import EchoCancel
import Foundation

/// Normalized LMS canceller. Feed the call audio as the reference and the
/// microphone as the signal to clean. The reference should lead the microphone
/// by roughly the capture delay so the echo lands inside the filter.
public final class EchoCanceller {
    public let filterLength: Int
    private let state: OpaquePointer

    public init(filterLength: Int = 3200, stepSize: Float = 0.2) {
        self.filterLength = max(filterLength, 1)
        guard let state = echo_cancel_create(Int32(self.filterLength), stepSize) else {
            preconditionFailure("Could not create the echo canceller")
        }
        self.state = state
    }

    deinit {
        echo_cancel_destroy(state)
    }

    public func reset() {
        echo_cancel_reset(state)
    }

    public func process(microphone: [Int16], reference: [Int16]) -> [Int16] {
        let count = min(microphone.count, reference.count)
        guard count > 0 else { return [] }
        var output = [Int16](repeating: 0, count: count)
        microphone.withUnsafeBufferPointer { mic in
            reference.withUnsafeBufferPointer { ref in
                output.withUnsafeMutableBufferPointer { out in
                    echo_cancel_process(
                        state,
                        mic.baseAddress,
                        ref.baseAddress,
                        out.baseAddress,
                        Int32(count)
                    )
                }
            }
        }
        return output
    }
}
