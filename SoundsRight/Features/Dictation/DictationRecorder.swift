import Accelerate
import AVFoundation
import CoreAudio
import Foundation
import os

/// Captures microphone audio into memory as mono 16 kHz Float32.
///
/// Nothing is written to disk. `DictationController` decides — per activation,
/// from which shortcut fired — whether the returned samples are also saved as a
/// WAV; the default path drops them as soon as the transcript is produced.
@MainActor
final class DictationRecorder {

    // MARK: - Published State

    /// Smoothed 0...1 input level, for the HUD meter.
    private(set) var level: Float = 0
    private(set) var isRecording = false

    /// Captured duration so far, derived from the sample count so it can never
    /// drift away from the audio the transcriber will actually see.
    var elapsed: TimeInterval { sink.duration(atSampleRate: AppConstants.dictationSampleRate) }

    // MARK: - Services

    /// Built fresh by every `start()` and released by `teardown()` — see `start()`.
    private var engine: AVAudioEngine?
    private let sink = SampleSink()
    private var converter: AVAudioConverter?
    private var meterTask: Task<Void, Never>?

    /// Invoked on the main actor whenever the level or elapsed time changes, so
    /// the HUD can redraw without the recorder having to be an ObservableObject.
    var onMeterUpdate: (@MainActor (Float, TimeInterval) -> Void)?
    /// Fired when the max-duration ceiling stops an unattended recording.
    var onDurationLimitReached: (@MainActor () -> Void)?

    private let logger = Logger(subsystem: "com.soundsright.desktop", category: "DictationRecorder")

    // MARK: - Permission

    /// Requests microphone access, returning the resulting authorization.
    /// Prompting is the only public API that registers the app in the
    /// Microphone list, so it runs even when the answer is already known.
    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    static var hasMicrophoneAccess: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - Core Actions

    func start() throws {
        guard !isRecording else { return }

        // Asked of CoreAudio directly: the engine's input format is not a
        // reliable signal on its own, and a Mac mini or Mac Studio with nothing
        // plugged in has no input device at all.
        guard Self.hasDefaultInputDevice else {
            throw DictationError.noAudioInput
        }

        // Capacity is claimed here, on the main actor, rather than left to grow
        // under the tap: reallocating means a malloc and a copy of everything
        // captured so far, on a real-time thread that must not block.
        sink.reset(reservingSamples: Int(
            AppConstants.dictationSampleRate * AppConstants.dictationCaptureReserveDuration
        ))

        // A fresh engine per recording: an AVAudioEngine's input node binds to
        // the default input device the first time it is touched and keeps that
        // binding, so a long-lived engine never sees a microphone connected —
        // or picked in System Settings → Sound — after it was built.
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        // A zero sample rate means CoreAudio handed back a placeholder format:
        // no usable input device, or the device disappeared mid-setup.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw DictationError.noAudioInput
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AppConstants.dictationSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw DictationError.recordingFailed("Could not configure the 16 kHz capture format.")
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw DictationError.recordingFailed("Could not convert the microphone format to 16 kHz mono.")
        }
        self.converter = converter

        let sink = self.sink
        let maxSamples = Int(AppConstants.dictationMaxDuration * AppConstants.dictationSampleRate)

        // The tap runs on a real-time audio thread: it must not hop actors or
        // allocate unpredictably, so conversion writes straight into the
        // lock-guarded sink and the main actor polls it from `startMetering`.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            guard let converted = Self.convert(buffer, using: converter, to: targetFormat) else { return }
            sink.append(converted, limit: maxSamples)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            self.converter = nil
            throw DictationError.recordingFailed(error.localizedDescription)
        }

        self.engine = engine
        isRecording = true
        startMetering()
        logger.info("Dictation recording started at \(inputFormat.sampleRate, privacy: .public) Hz input")
    }

    /// Stops capture and returns the clip. A short tail is captured first so the
    /// final syllable — released at the same moment as the hotkey — survives.
    func finish() async -> DictationAudio {
        guard isRecording else {
            return DictationAudio(samples: [], sampleRate: AppConstants.dictationSampleRate)
        }

        try? await Task.sleep(nanoseconds: UInt64(AppConstants.dictationStopTailDuration * 1_000_000_000))
        teardown()

        let audio = DictationAudio(
            samples: sink.drain(),
            sampleRate: AppConstants.dictationSampleRate
        )
        logger.info("Dictation recording finished: \(String(format: "%.2f", audio.duration), privacy: .public)s")
        return audio
    }

    /// Stops capture and throws the audio away (Esc, or a failed activation).
    func cancel() {
        guard isRecording else { return }
        teardown()
        sink.reset()
        logger.info("Dictation recording cancelled")
    }

    // MARK: - Helpers

    private func teardown() {
        isRecording = false
        meterTask?.cancel()
        meterTask = nil
        level = 0
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
    }

    /// Whether macOS currently has an input device to record from.
    private static var hasDefaultInputDevice: Bool {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return status == noErr && deviceID != kAudioObjectUnknown
    }

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRecording else { return }

                // Attack fast, release slow: a meter that decays at the same
                // rate it rises reads as jitter rather than as speech.
                let instant = self.sink.recentLevel()
                self.level = instant > self.level
                    ? instant
                    : self.level * 0.82 + instant * 0.18

                let elapsed = self.elapsed
                self.onMeterUpdate?(self.level, elapsed)

                if elapsed >= AppConstants.dictationMaxDuration {
                    self.logger.info("Dictation hit the duration ceiling — stopping")
                    self.onDurationLimitReached?()
                    return
                }

                try? await Task.sleep(nanoseconds: AppConstants.dictationMeterIntervalNanoseconds)
            }
        }
    }

    /// Resamples one tap buffer to 16 kHz mono. Returns nil for the buffers the
    /// converter legitimately absorbs without producing output yet.
    private nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            // The converter pulls until it is told there is no more input; handing
            // the same buffer over twice would duplicate audio.
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

// MARK: - Sample Sink

/// Lock-guarded accumulator shared between the real-time audio tap and the main
/// actor. `@unchecked Sendable` is deliberate: the audio thread cannot await, so
/// an actor is the wrong tool and an explicit lock is the correct one.
private final class SampleSink: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    /// How much room `reset` claims up front, so a typical dictation never
    /// reallocates while the tap is running.
    private var reservedSamples = 0
    /// Peak of the most recent tap buffer, for the level meter.
    private var lastBufferPeak: Float = 0

    func append(_ buffer: AVAudioPCMBuffer, limit: Int) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        // Vectorized: this is the real-time path, and the peak is computed for
        // every buffer whether or not the meter reads it.
        var peak: Float = 0
        vDSP_maxmgv(channel, 1, &peak, vDSP_Length(frameCount))

        lock.lock()
        defer { lock.unlock() }

        lastBufferPeak = peak
        guard samples.count < limit else { return }
        let room = limit - samples.count
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: min(frameCount, room)))
    }

    func recentLevel() -> Float {
        lock.lock()
        defer { lock.unlock() }
        // Speech peaks well below full scale; ×2.2 makes normal talking fill
        // most of the meter without clipping the display on loud syllables.
        return min(1, lastBufferPeak * 2.2)
    }

    func duration(atSampleRate sampleRate: Double) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / sampleRate
    }

    /// Hands over the captured samples and empties the sink.
    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let captured = samples
        samples = []
        samples.reserveCapacity(reservedSamples)
        lastBufferPeak = 0
        return captured
    }

    func reset(reservingSamples: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let reservingSamples {
            reservedSamples = reservingSamples
        }
        samples = []
        samples.reserveCapacity(reservedSamples)
        lastBufferPeak = 0
    }
}
