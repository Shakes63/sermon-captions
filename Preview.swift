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
    /// Off at an end that cuts or crossfades to an intro or outro.
    var fadeIn = true
    var fadeOut = true
    /// The saved video runs from `start` to `end` (seconds in the source).
    var start = 0.0
    var end = 0.0
    /// "Even out the volume" as a plain multiplier (1 = off), and whether
    /// the save's limiter is on (it is whenever the volume is evened out).
    var gain: Float = 1
    var limit = false
    /// The picture only fades while playing, so a paused or scrubbed frame
    /// is always the real one (picking the exact start frame needs that).
    var playing = false
    /// The first kept frame starts at `cutIn` and the last ends at `cutOut`.
    var cutIn = 0.0
    var cutOut = 0.0
    var frameRate = 30.0
    var keptFrames = 0
    var intro: ClipTiming?
    var outro: ClipTiming?
    /// While "Play the transition" runs: before the start and after the end,
    /// the intro and outro play instead of the rest of the service.
    var showClips = false

    static let fadeSeconds = 1.0
    /// The save's limiter: -1.5 dBFS, 50 ms release.
    static let limit: Float = 0.8414
    static let limiterRelease = 0.05

    /// Fade multiplier at time t: up over the first second, down over the
    /// last, like ffmpeg's fade/afade. Outside the saved part nothing
    /// changes (that part isn't in the video at all).
    func fadeLevel(_ t: Double) -> Double {
        guard fade, t >= start, t <= end, end - start > 2 * Self.fadeSeconds else { return 1 }
        let up = fadeIn ? (t - start) / Self.fadeSeconds : 1
        let down = fadeOut ? (end - t) / Self.fadeSeconds : 1
        return min(up, down, 1)
    }

    func inside(_ t: Double) -> Bool { t >= start && t <= end }

    /// What the sermon's sound is multiplied by after the volume change: the
    /// fades, and the equal-power crossfades into and out of the intro and
    /// outro (ffmpeg's acrossfade with qsin curves). Silent outside the
    /// saved part while the intro and outro play there.
    func sermonLevel(_ t: Double) -> Double {
        guard inside(t) else { return showClips ? 0 : 1 }
        // Next to an intro or outro, the sermon's sound starts (and stops) right at the cut.
        if showClips && ((intro != nil && t < cutIn) || (outro != nil && t >= cutOut)) { return 0 }
        var level = fadeLevel(t)
        if let c = intro, c.overlap > 0, t < cutIn + c.overlap {
            level *= sin(.pi / 2 * max(t - cutIn, 0) / c.overlap)
        }
        if let c = outro, c.overlap > 0, t > cutOut - c.overlap {
            level *= sin(.pi / 2 * max(cutOut - t, 0) / c.overlap)
        }
        return level
    }

    /// What an intro or outro's sound is multiplied by after its own volume
    /// change: the other half of the crossfade where it overlaps the
    /// sermon, full where it's on its own (only heard while it plays there).
    func clipLevel(_ slot: ClipSlot, _ t: Double) -> Double {
        guard let c = slot == .intro ? intro : outro, t >= c.start, t < c.end else { return 0 }
        if t >= cutIn && t < cutOut {
            guard c.overlap > 0 else { return 0 }
            let p = slot == .intro ? (cutIn + c.overlap - t) / c.overlap : (t - cutOut + c.overlap) / c.overlap
            return sin(.pi / 2 * min(max(p, 0), 1))
        }
        return showClips ? 1 : 0
    }

    /// The picture at t: how much of the intro or outro is mixed over the
    /// sermon (1 = only the clip, or black if it isn't there). Like ffmpeg's
    /// xfade, the first frame of a crossfade is all the outgoing picture.
    /// Which frame of the saved sermon t falls in (counted by frame, since
    /// the compositor asks for times right on the frame boundaries).
    func keptFrame(_ t: Double) -> Int { Int(((t - cutIn) * frameRate + 0.5).rounded(.down)) }

    func clipMix(_ t: Double) -> (slot: ClipSlot, weight: Double)? {
        let j = keptFrame(t)
        if j >= 0 && j < keptFrames {
            guard playing else { return nil }
            if let c = intro, j < c.frames { return (.intro, 1 - Double(j) / Double(c.frames)) }
            if let c = outro, j >= keptFrames - c.frames {
                return (.outro, Double(j - keptFrames + c.frames) / Double(c.frames))
            }
            return nil
        }
        guard showClips, (j < 0 ? intro : outro) != nil else { return nil }
        return (j < 0 ? .intro : .outro, 1)
    }
}

/// Where an intro or outro sits in the source video's time while previewing.
struct ClipTiming {
    /// Its first frame and the end of its last.
    var start: Double
    var end: Double
    /// The crossfade with the sermon, in frames and seconds (0 = a cut).
    var frames: Int
    var overlap: Double
    /// Its volume change (1 = none), and whether the limiter is on.
    var gain: Float
    var limit: Bool
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
    /// The intro's or outro's sound, or (nil) the sermon's.
    let clip: ClipSlot?
    var sampleRate = 48000.0
    var isFloat = false
    /// Limiter: the level it's following, and how fast it lets go.
    var envelope: Float = 0
    var release: Float = 0.9996

    init(_ state: PreviewState, clip: ClipSlot?) {
        self.state = state
        self.clip = clip
    }
}

/// An audio tap that applies the volume change, limiter and fades to one
/// track, in the save's order. Every audio track in the preview gets one,
/// so the mix as a whole is changed the same way the saved sound is; an
/// intro's or outro's (`clip`) follows that clip's settings.
func makePreviewTap(_ state: PreviewState, clip: ClipSlot? = nil) -> MTAudioProcessingTap? {
    var callbacks = MTAudioProcessingTapCallbacks(
        version: kMTAudioProcessingTapCallbacksVersion_0,
        clientInfo: Unmanaged.passRetained(TapContext(state, clip: clip)).toOpaque(),
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
            // The sermon's sound outside the saved part, or in its middle
            // with no volume change, stays as it is.
            if ctx.clip == nil {
                let t1 = t0 + Double(n) / ctx.sampleRate
                if t1 < s.start || t0 > s.end {
                    if !s.showClips { return }
                } else if s.gain == 1 && !s.limit {
                    let edge = max(s.fade ? PreviewSettings.fadeSeconds : 0, s.intro?.overlap ?? 0, s.outro?.overlap ?? 0)
                    if t0 >= max(s.start, s.cutIn) + edge && t1 <= min(s.end, s.cutOut) - edge { return }
                }
            }
            // The volume change and limiter (inside the saved part, for the
            // sermon), then the fades.
            let timing = ctx.clip.flatMap { $0 == .intro ? s.intro : s.outro }
            var gains = [Float](repeating: 1, count: n)
            var levels = [Float](repeating: 1, count: n)
            var limiting = false
            for i in 0..<n {
                let t = t0 + Double(i) / ctx.sampleRate
                if let clip = ctx.clip {
                    gains[i] = timing?.gain ?? 1
                    levels[i] = Float(s.clipLevel(clip, t))
                    limiting = limiting || timing?.limit == true
                } else {
                    if s.inside(t) {
                        gains[i] = s.gain
                        limiting = limiting || s.limit
                    }
                    levels[i] = Float(s.sermonLevel(t))
                }
            }
            // Nothing to do if every sample stays as it is.
            if !limiting && !gains.contains(where: { $0 != 1 }) && !levels.contains(where: { $0 != 1 }) { return }
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
                vDSP_vmul(data, stride, gains, 1, data, stride, vDSP_Length(frames))
            }
            if limiting {
                // Like the save's limiter: hold peaks under -1.5 dBFS, all
                // channels together, letting go over 50 ms. (No look-ahead, so
                // it grabs the very sample that's too loud; close enough to hear.)
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
            }
            for (data, stride) in channels {
                vDSP_vmul(data, stride, levels, 1, data, stride, vDSP_Length(frames))
            }
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

/// The picture once there's an intro or outro: the player has the clips as
/// tracks of their own, and a crossfade needs two frames at once, which
/// takes a compositor of our own.
final class JoinInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    /// A track's frames and where they go in the picture.
    struct Placed {
        let track: CMPersistentTrackID
        /// Turns the decoded frame upright.
        let orientation: CGImagePropertyOrientation
        /// Where it lands (Core Image coordinates: origin bottom left).
        let rect: CGRect

        /// The frame as the save takes it: decoded with its own YUV matrix,
        /// then the values read as bt709 whatever else it's tagged with.
        func image(_ buffer: CVPixelBuffer) -> CIImage {
            var image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: JoinCompositor.space]).oriented(orientation)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            let scale = CGAffineTransform(scaleX: rect.width / max(image.extent.width, 1),
                                          y: rect.height / max(image.extent.height, 1))
            return image.transformed(by: scale.concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
        }
    }

    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let sermon: Placed
    let clips: [ClipSlot: Placed]
    let size: CGSize
    let state: PreviewState
    let look: (table: Data, space: CGColorSpace)?

    init(timeRange: CMTimeRange, sermon: Placed, clips: [ClipSlot: Placed], size: CGSize, state: PreviewState,
         look: (table: Data, space: CGColorSpace)?) {
        self.timeRange = timeRange
        self.sermon = sermon
        self.clips = clips
        self.size = size
        self.state = state
        self.look = look
        requiredSourceTrackIDs = ([sermon.track] + clips.values.map(\.track)).map { NSNumber(value: $0) }
    }
}

final class JoinCompositor: NSObject, AVVideoCompositing {
    let sourcePixelBufferAttributes: [String: any Sendable]? =
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] =
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    private let context = CIContext(options: [.cacheIntermediates: false])
    /// The saved video's colours (bt709), the space ffmpeg's xfade mixes in.
    static let space = CGColorSpace(name: CGColorSpace.itur_709)!

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let ins = request.videoCompositionInstruction as? JoinInstruction,
              let out = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "SermonCaptions", code: 1))
            return
        }
        let t = request.compositionTime.seconds
        let rect = CGRect(origin: .zero, size: ins.size)
        let black = CIImage(color: .black).cropped(to: rect)
        var picture = black
        if let frame = request.sourceFrame(byTrackID: ins.sermon.track) {
            // The table maps the video's own values, which is how the frame is read here.
            let cube = ins.look.flatMap { AutoColor.filter($0.table, space: Self.space) }
            picture = previewFrame(ins.sermon.image(frame), at: t, state: ins.state, cube: cube).composited(over: black)
        }
        if let (slot, weight) = ins.state.settings.clipMix(t) {
            var clip = black
            if let placed = ins.clips[slot], let frame = request.sourceFrame(byTrackID: placed.track) {
                clip = placed.image(frame).composited(over: black)
            }
            picture = weight >= 1 ? clip : Self.mix(picture, clip, weight)
        }
        context.render(picture.cropped(to: rect), to: out, bounds: rect, colorSpace: Self.space)
        request.finish(withComposedVideoFrame: out)
    }

    /// `b` over `a` at `weight`, mixed in the video's own (bt709) values
    /// rather than linear light, as ffmpeg's xfade does.
    static func mix(_ a: CIImage, _ b: CIImage, _ weight: Double) -> CIImage {
        guard let ea = a.matchedFromWorkingSpace(to: space), let eb = b.matchedFromWorkingSpace(to: space) else {
            return weight < 0.5 ? a : b
        }
        return ea.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: eb, kCIInputTimeKey: weight,
        ]).matchedToWorkingSpace(from: space) ?? b
    }
}

// MARK: - Loudness

/// Integrated loudness (LUFS) of `length` seconds from `start`, measured by
/// the bundled ffmpeg (EBU R128).
/// `dualMono`: a one-channel file that will be saved as the same sound on
/// both sides (the repaired voice) measures 3 dB louder that way.
/// `stereo`: measured as the save mixes it down to two channels.
func measureLoudness(_ url: URL, start: Double, length: Double, dualMono: Bool = false,
                     stereo: Bool = false) async -> Double? {
    let ffmpeg = Paths.resources.appendingPathComponent("bin/ffmpeg")
    return await Task.detached(priority: .userInitiated) { () -> Double? in
        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = ["-nostdin", "-hide_banner", "-nostats", "-ss", String(format: "%.3f", start),
                       "-t", String(format: "%.3f", length), "-i", url.path, "-map", "0:a:0",
                       "-af", (stereo ? "aresample=48000,aformat=sample_fmts=flt:channel_layouts=stereo," : "")
                           + "ebur128=framelog=quiet" + (dualMono ? ":dualmono=true" : ""), "-f", "null", "-"]
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
