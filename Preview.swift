// Live preview of what Save does to the sound and the fades: the trim
// window's player reads these settings while it plays, so turning a switch
// or moving the start/end is heard and seen straight away.

import AVFoundation
import Accelerate
import CoreImage
import MediaToolbox
import os

/// What the saved video will do, in the source video's time.
struct PreviewSettings {
    var fade = false
    /// The saved video runs from `start` to `end` (seconds in the source).
    var start = 0.0
    var end = 0.0
    /// "Even out the volume" as a plain multiplier (1 = off).
    var gain: Float = 1
    /// The picture only fades while playing, so a paused or scrubbed frame
    /// is always the real one (picking the exact start frame needs that).
    var playing = false

    static let fadeSeconds = 1.0
    /// The save's limiter: -1.5 dBFS, 50 ms release.
    static let limit: Float = 0.8414
    static let limiterRelease = 0.05

    /// Fade multiplier at time t: up over the first second, down over the
    /// last, like ffmpeg's fade/afade. Outside the saved part nothing
    /// changes (that part isn't in the video at all).
    func fadeLevel(_ t: Double) -> Double {
        guard fade, t >= start, t <= end, end - start > 2 * Self.fadeSeconds else { return 1 }
        return min(min((t - start) / Self.fadeSeconds, (end - t) / Self.fadeSeconds), 1)
    }

    func inside(_ t: Double) -> Bool { t >= start && t <= end }
}

final class PreviewState: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: PreviewSettings())

    var settings: PreviewSettings { lock.withLock { $0 } }

    func update(_ change: (inout PreviewSettings) -> Void) {
        lock.withLock { change(&$0) }
    }
}

// MARK: - Sound

/// Lives as the tap's storage: the shared settings plus the stream format.
private final class TapContext {
    let state: PreviewState
    var sampleRate = 48000.0
    var isFloat = false
    /// Limiter: the level it's following, and how fast it lets go.
    var envelope: Float = 0
    var release: Float = 0.9996

    init(_ state: PreviewState) { self.state = state }
}

/// An audio tap that applies the fades and the volume change to one track.
/// Every audio track in the preview gets one, so the mix as a whole is
/// changed the same way the saved sound is.
func makePreviewTap(_ state: PreviewState) -> MTAudioProcessingTap? {
    var callbacks = MTAudioProcessingTapCallbacks(
        version: kMTAudioProcessingTapCallbacksVersion_0,
        clientInfo: Unmanaged.passRetained(TapContext(state)).toOpaque(),
        init: { _, clientInfo, storage in storage.pointee = clientInfo },
        finalize: { tap in
            Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
        },
        prepare: { tap, _, format in
            let ctx = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
            ctx.sampleRate = format.pointee.mSampleRate
            ctx.isFloat = format.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
                && format.pointee.mBitsPerChannel == 32
            ctx.release = Float(exp(-1 / (PreviewSettings.limiterRelease * ctx.sampleRate)))
            ctx.envelope = 0
        },
        unprepare: nil,
        process: { tap, frames, _, buffers, framesOut, flagsOut in
            var range = CMTimeRange()
            guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, &range, framesOut) == noErr
            else { return }
            let ctx = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
            guard ctx.isFloat, range.start.isValid else { return }
            let s = ctx.state.settings
            let t0 = range.start.seconds
            let n = Int(framesOut.pointee)
            let t1 = t0 + Double(n) / ctx.sampleRate
            // Nothing to do if this whole buffer is outside the saved part, or
            // inside it with neither a fade nor a volume change.
            if t1 < s.start || t0 > s.end { return }
            if s.gain == 1 && (!s.fade || (t0 >= s.start + PreviewSettings.fadeSeconds
                                          && t1 <= s.end - PreviewSettings.fadeSeconds)) { return }
            var levels = [Float](repeating: 1, count: n)
            for i in 0..<n {
                let t = t0 + Double(i) / ctx.sampleRate
                if s.inside(t) { levels[i] = s.gain * Float(s.fadeLevel(t)) }
            }
            // Every channel, interleaved or not, as (first sample, stride).
            var channels: [(UnsafeMutablePointer<Float>, Int)] = []
            var frames = n
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let count = max(Int(buffer.mNumberChannels), 1)
                frames = min(frames, Int(buffer.mDataByteSize) / 4 / count)
                for c in 0..<count { channels.append((data + c, count)) }
            }
            for (data, stride) in channels {
                vDSP_vmul(data, stride, levels, 1, data, stride, vDSP_Length(frames))
            }
            guard s.gain > 1 else { return }
            // Like the save's limiter: hold peaks under -1.5 dBFS, all channels
            // together, letting go over 50 ms. (No look-ahead, so it grabs the
            // very sample that's too loud; close enough to hear.)
            let limit = PreviewSettings.limit
            var env = ctx.envelope
            for i in 0..<frames {
                var peak: Float = 0
                for (data, stride) in channels { peak = max(peak, abs(data[i * stride])) }
                env = max(peak, env * ctx.release)
                if env > limit {
                    let g = limit / env
                    for (data, stride) in channels { data[i * stride] *= g }
                }
            }
            ctx.envelope = env
        })
    var tap: MTAudioProcessingTap?
    guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                     kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr else {
        Unmanaged<TapContext>.fromOpaque(callbacks.clientInfo!).release()
        return nil
    }
    return tap
}

// MARK: - Picture

/// The picture for one frame: Auto color (if on), then the fade (while
/// playing). ffmpeg fades the encoded values; Core Image works in linear
/// light, so the same fade is roughly the 2.2 power.
func previewFrame(_ source: CIImage, at t: Double, state: PreviewState, cube: CIFilter?) -> CIImage {
    var image = source
    if let cube {
        cube.setValue(image, forKey: kCIInputImageKey)
        image = cube.outputImage ?? image
    }
    let s = state.settings
    let level = s.playing ? s.fadeLevel(t) : 1
    if level < 1 {
        let k = CGFloat(pow(level, 2.2))
        image = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
        ])
    }
    return image
}

// MARK: - Loudness

/// Integrated loudness (LUFS) of `length` seconds from `start`, measured by
/// the bundled ffmpeg (EBU R128).
/// `dualMono`: a one-channel file that will be saved as the same sound on
/// both sides (the repaired voice) measures 3 dB louder that way.
func measureLoudness(_ url: URL, start: Double, length: Double, dualMono: Bool = false) async -> Double? {
    let ffmpeg = Paths.resources.appendingPathComponent("bin/ffmpeg")
    return await Task.detached(priority: .userInitiated) { () -> Double? in
        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = ["-nostdin", "-hide_banner", "-nostats", "-ss", String(format: "%.3f", start),
                       "-t", String(format: "%.3f", length), "-i", url.path, "-map", "0:a:0",
                       "-af", "ebur128=framelog=quiet" + (dualMono ? ":dualmono=true" : ""), "-f", "null", "-"]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        // The summary's "I:  -23.4 LUFS" line.
        guard let m = text.range(of: #"I:\s+-?[0-9.]+ LUFS"#, options: [.regularExpression, .backwards])
        else { return nil }
        return Double(text[m].dropFirst(2).replacingOccurrences(of: "LUFS", with: "")
            .trimmingCharacters(in: .whitespaces))
    }.value
}
