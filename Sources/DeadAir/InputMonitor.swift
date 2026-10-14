import Accelerate
import CoreAudio
import Foundation
import os

/// Taps one input device with a HAL IOProc and accumulates the peak level
/// between polls. Doesn't change the device or its format, so it coexists with
/// whatever app is doing the actual recording.
final class InputMonitor {
    struct Meter {
        /// Highest absolute sample value seen since the last drain (0...1).
        var peak: Float = 0
        /// Number of IO cycles since the last drain; 0 means the device delivered nothing.
        var callbacks = 0
    }

    let device: InputDevice
    private var procID: AudioDeviceIOProcID?
    private let meter = OSAllocatedUnfairLock(initialState: Meter())

    init(device: InputDevice) {
        self.device = device
    }

    deinit { stop() }

    func start() -> OSStatus {
        guard procID == nil else { return noErr }
        let isFloat = AudioSystem.inputIsFloat32(device.id)
        let meter = self.meter

        var proc: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&proc, device.id, nil) { _, input, _, _, _ in
            let peak = InputMonitor.peak(of: input, isFloat: isFloat)
            meter.withLock {
                $0.peak = max($0.peak, peak)
                $0.callbacks += 1
            }
        }
        guard status == noErr, let proc else { return status }

        status = AudioDeviceStart(device.id, proc)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(device.id, proc)
            return status
        }
        procID = proc
        return noErr
    }

    func stop() {
        guard let procID else { return }
        AudioDeviceStop(device.id, procID)
        AudioDeviceDestroyIOProcID(device.id, procID)
        self.procID = nil
    }

    /// Returns the meter accumulated since the previous call and resets it.
    func drain() -> Meter {
        meter.withLock { meter in
            defer { meter = Meter() }
            return meter
        }
    }

    /// Runs on the real-time IO thread: no allocation, no Objective-C.
    private static func peak(of list: UnsafePointer<AudioBufferList>, isFloat: Bool) -> Float {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        var peak: Float = 0
        for buffer in buffers {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            if isFloat {
                var bufferPeak: Float = 0
                let count = vDSP_Length(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                vDSP_maxmgv(data.assumingMemoryBound(to: Float.self), 1, &bufferPeak, count)
                peak = max(peak, bufferPeak.isFinite ? bufferPeak : 1)
            } else {
                // Can't meter an unknown integer format, but any non-zero byte is signal.
                let bytes = UnsafeRawBufferPointer(start: data, count: Int(buffer.mDataByteSize))
                if bytes.contains(where: { $0 != 0 }) { peak = 1 }
            }
        }
        return peak
    }
}
