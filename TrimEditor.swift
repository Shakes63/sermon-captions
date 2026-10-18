// The trim window: a player plus two timelines (the whole video, and a
// zoomed-in strip around the playhead) for picking the start and end frame,
// sections where music behind the speaking can be turned down, and an intro
// and outro to put before and after it.

import AVFoundation
import AVKit
import Accelerate
import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

struct TrimPoints: Codable {
    var inTime: Double
    var outTime: Double
    var fade: Bool
    var level: Bool
    var musicSections: [MusicSection]?
    var autoColor: Bool?
    var repair: Bool?
    var intro: String?
    var outro: String?
    // A single section, as saved by the first version with music.
    var musicFrom: Double?
    var musicTo: Double?
    var music: String?
}

/// From `sermon_captions.py suggest`: a cut point in a pause, the far edge of
/// that pause, his first (or last) word there, and the words it's based on.
struct TrimSuggestion: Codable, Hashable {
    var time: Double
    var room: Double
    var word: Double
    var why: String
}

struct TrimSuggestions: Codable {
    var starts: [TrimSuggestion]
    var ends: [TrimSuggestion]
    var duration: Double?
}

/// A stretch with music behind the speaking: first and last frame (like the
/// start and end), and what to do with the music there.
struct MusicSection: Codable, Identifiable, Equatable {
    var id = UUID()
    var from: Double
    var to: Double
    var choice: MusicChoice
}

enum MusicChoice: String, Codable, CaseIterable, Identifiable {
    case original, down, removed
    var id: Self { self }

    var title: String {
        switch self {
        case .original: "Original"
        case .down: "Turned down"
        case .removed: "Removed"
        }
    }

    /// How much of the separated audio to add. It holds minus the music, so
    /// 1 removes the music and 1 - 10^(-12/20) leaves it 12 dB quieter.
    var amount: Double {
        switch self {
        case .original: 0
        case .down: 1 - pow(10, -12.0 / 20)
        case .removed: 1
        }
    }
}

/// A video saved as it is before (intro) or after (outro) the part being kept.
struct Clip: Equatable {
    let url: URL
    let duration: Double
}

enum ClipSlot {
    case intro, outro
    var name: String { self == .intro ? "intro" : "outro" }
    /// The last one chosen, which a new sermon starts with.
    var defaultsKey: String { self == .intro ? "lastIntro" : "lastOutro" }
}

/// Owns the player and the start/end points. Times are always snapped to the
/// start of a frame; the end point is the last frame kept (inclusive).
@MainActor
final class TrimController: ObservableObject {
    nonisolated static let peaksPerSecond = 50.0
    static let thumbCount = 60

    let url: URL
    let player: AVPlayer
    private let asset: AVURLAsset
    @Published private(set) var ready = false
    @Published private(set) var loadError: String?
    @Published private(set) var duration = 0.0
    @Published private(set) var fps = 30.0
    @Published private(set) var current = 0.0
    @Published private(set) var playing = false {
        didSet { if playing != oldValue { preview.update { $0.playing = playing } } }
    }
    /// Playing backwards (J): Space and the play button then go forward.
    @Published private(set) var reversing = false
    @Published private(set) var inPoint = 0.0
    @Published private(set) var outPoint = 0.0
    @Published var fade = false {
        didSet {
            guard fade != oldValue else { return }
            onChange?()
            updatePreview()
            applyLook()
        }
    }
    @Published var level = false {
        didSet {
            guard level != oldValue else { return }
            onChange?()
            levelChanged()
        }
    }
    /// Measuring the loudness for "Even out the volume".
    @Published private(set) var levelBusy = false
    /// The volume change "Even out the volume" will make, once measured.
    @Published private(set) var levelGain: Double?
    @Published var autoColor = false {
        didSet {
            guard autoColor != oldValue else { return }
            onChange?()
            colorChanged()
        }
    }
    /// Measuring the colour for Auto color.
    @Published private(set) var colorBusy = false
    /// "Repair the voice": play and save the AI-rebuilt voice (off by default;
    /// it takes about 10 minutes per sermon).
    @Published var repair = false {
        didSet {
            guard repair != oldValue else { return }
            onChange?()
            applyMix()
            redrawWaveform()
            if level { levelChanged() }   // the repaired voice is a different loudness
        }
    }
    /// The repaired voice that fits the current start, end and music, if made.
    @Published private(set) var repairTake: RepairTake?
    /// The waveform as drawn: the sound as it will be saved (volume, fades,
    /// music choices), one peak per 1/50 s, square-rooted for display.
    @Published private(set) var peaks: [Float] = []
    /// The original sound, mono at 2 kHz, and its peaks before any changes.
    private var wave: [Int16] = []
    private var rawPeaks: [Float] = []
    /// Each separated file (minus the music), mono at 2 kHz.
    private var musicWave: [URL: [Float]] = [:]
    @Published private(set) var thumbs: [CGImage?] = Array(repeating: nil, count: thumbCount)
    /// In time order, never overlapping.
    @Published private(set) var sections: [MusicSection] = []
    /// Separated audio for each section that has it.
    @Published private(set) var musicFiles: [UUID: URL] = [:]
    /// The section the 1 2 3 keys change when the playhead isn't in one.
    @Published private(set) var activeSection: UUID?
    /// Set when the preview of the separated audio can't be trusted.
    @Published private(set) var musicPreviewNote: String?
    @Published private(set) var suggestions: TrimSuggestions?
    /// Which of the suggested starts and ends is showing.
    @Published var startPick = 0
    @Published var endPick = 0
    @Published private(set) var intro: Clip?
    @Published private(set) var outro: Clip?
    /// Set when a saved intro or outro can't be found any more.
    @Published private(set) var clipNote: String?
    var onChange: (() -> Void)?

    private var observer: Any?
    private var seekTarget: Double?
    private var seeking = false
    private var stopAt: Double?
    private var stopReturn: Double?
    private var generator: AVAssetImageGenerator?
    private var itemWatch: Task<Void, Never>?
    private var itemBuild: Task<Void, Never>?
    private var musicTracks: [UUID: CMPersistentTrackID] = [:]
    /// The separated files the player was last (re)built for, worked or not.
    private var builtFor: [UUID: URL]?
    /// The original sound's track in whatever the player is playing.
    private var soundTrack: CMPersistentTrackID?
    /// Fades and volume, read live by the player's picture and sound.
    let preview = PreviewState()
    private var loudness: (key: String, gainDB: Double)?
    private var levelTask: Task<Bool, Never>?
    /// The Auto color table, and the kept part it was measured on.
    private var color: (key: String, table: Data, space: CGColorSpace, file: URL)?
    private var colorTask: Task<Bool, Never>?
    /// The section "play section" is playing, so 1 2 3 change it even during
    /// the run-up, when the playhead may still be in the one before.
    private var playingSection: UUID?
    /// Set once the window has moved on to another video.
    private var closed = false

    init(url: URL, saved: TrimPoints?) {
        self.url = url
        asset = AVURLAsset(url: url)
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.actionAtItemEnd = .pause
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) {
            [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        Task { await load(saved) }
    }

    func shutdown() {
        closed = true
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        generator?.cancelAllCGImageGeneration()
        itemWatch?.cancel()
        itemBuild?.cancel()
    }

    // MARK: frames

    var frameDuration: Double { 1 / fps }
    /// The player's time right now (between frames too), for smooth drawing.
    var smoothTime: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? min(max(t, 0), duration) : current
    }
    func frame(_ t: Double) -> Int { Int((t * fps + 1e-3).rounded(.down)) }
    func time(_ frame: Int) -> Double { Double(frame) / fps }
    var lastFrame: Int { max(0, Int((duration * fps - 1e-3).rounded(.up)) - 1) }
    func snap(_ t: Double) -> Double { time(min(max(frame(t), 0), lastFrame)) }
    var keptFrames: Int { frame(outPoint) - frame(inPoint) + 1 }
    var keptSeconds: Double { Double(keptFrames) / fps }
    /// The saved video's length, with the intro and outro.
    var savedSeconds: Double { keptSeconds + (intro?.duration ?? 0) + (outro?.duration ?? 0) }

    // MARK: loading

    private func load(_ saved: TrimPoints?) async {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let range = try? await track.load(.timeRange) else {
            loadError = "Couldn't read the video in \(url.lastPathComponent)."
            return
        }
        // The picture's length, not the file's: audio often runs a little longer.
        let d = range.end.seconds
        guard d.isFinite, d > 0 else {
            loadError = "Couldn't find the length of \(url.lastPathComponent)."
            return
        }
        duration = d
        if let rate = try? await track.load(.nominalFrameRate), rate > 0 {
            fps = Double(rate)
        }
        var clips: [(ClipSlot, String?)] = [(.intro, nil), (.outro, nil)]
        if let saved, saved.outTime > saved.inTime, saved.outTime <= d {
            clips = [(.intro, saved.intro), (.outro, saved.outro)]
            inPoint = snap(saved.inTime)
            outPoint = snap(saved.outTime)
            fade = saved.fade
            level = saved.level
            autoColor = saved.autoColor ?? false
            repair = saved.repair ?? false
            var list = saved.musicSections ?? []
            if list.isEmpty, let a = saved.musicFrom, let b = saved.musicTo {
                list = [MusicSection(from: a, to: b, choice: MusicChoice(rawValue: saved.music ?? "") ?? .original)]
            }
            for var m in list.sorted(by: { $0.from < $1.from }) where m.to > m.from && m.to <= d {
                m.from = snap(m.from)
                m.to = snap(m.to)
                if m.from > (sections.last?.to ?? -1) { sections.append(m) }
            }
        } else {
            inPoint = 0
            outPoint = time(lastFrame)
            // A new video starts with the fades, the volume and the colour on.
            fade = true
            level = true
            autoColor = true
            // And with the intro and outro the last sermon had.
            clips = [ClipSlot.intro, .outro].map { ($0, UserDefaults.standard.string(forKey: $0.defaultsKey)) }
        }
        var lost: [String] = []
        for (slot, path) in clips {
            guard let path else { continue }
            let url = URL(fileURLWithPath: path)
            if let d = await Self.clipLength(url) {
                setClip(slot, Clip(url: url, duration: d))
            } else {
                lost.append("The \(slot.name) (\(url.lastPathComponent)) can't be found, so it's been left off.")
            }
        }
        clipNote = lost.isEmpty ? nil : lost.joined(separator: " ")
        assetSoundTrack = try? await asset.loadTracks(withMediaType: .audio).first?.trackID
        soundTrack = assetSoundTrack
        ready = true
        checkSuggestions()
        updatePreview()
        applyMix()
        applyLook()
        seek(inPoint)
        loadWaveform()
        loadThumbnails(asset)
        watchItem()
        refreshMusic()
        if autoColor { colorChanged() }
        if level { levelChanged() }
    }

    /// A seek issued before the player item is ready can be dropped, so show
    /// the current frame again once it is (and report a file it can't play).
    /// After swapping items, `resume` picks up where the old one was.
    private func watchItem(resume: (time: Double, rate: Float)? = nil) {
        itemWatch?.cancel()
        guard let item = player.currentItem else { return }
        itemWatch = Task { [weak self] in
            for await status in item.publisher(for: \.status).values {
                guard let self, !Task.isCancelled else { return }
                if status == .readyToPlay {
                    if let resume {
                        self.seek(resume.time)
                        if resume.rate != 0 { self.player.rate = resume.rate }
                    } else if !self.playing {
                        self.seek(self.current)
                    }
                    return
                }
                if status == .failed {
                    if !self.musicTracks.isEmpty {
                        // Fall back to the plain video; saving doesn't use the preview.
                        self.musicPreviewNote = "The preview of the separated music couldn't play. Saving still works."
                        self.swapItem(AVPlayerItem(asset: self.asset), tracks: [:], sound: self.assetSoundTrack)
                    } else {
                        self.loadError = "Couldn't play \(self.url.lastPathComponent): "
                            + (item.error?.localizedDescription ?? "unknown error")
                    }
                    return
                }
            }
        }
    }

    private var assetSoundTrack: CMPersistentTrackID?

    private func swapItem(_ item: AVPlayerItem, tracks: [UUID: CMPersistentTrackID], sound: CMPersistentTrackID?) {
        let resume = (time: current, rate: player.rate)
        player.pause()   // not self.pause(): a running "play section" should carry on
        musicTracks = tracks
        soundTrack = sound
        player.replaceCurrentItem(with: item)
        applyMix()
        applyLook()
        watchItem(resume: resume)
    }

    /// Loudness envelope from the bundled ffmpeg: mono 2 kHz samples reduced
    /// to one peak per 1/50 s.
    private func loadWaveform() {
        let url = url
        let ffmpeg = Paths.resources.appendingPathComponent("bin/ffmpeg")
        Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = ffmpeg
            p.arguments = ["-nostdin", "-loglevel", "error", "-i", url.path, "-map", "0:a:0",
                           "-ac", "1", "-ar", "2000", "-f", "s16le", "-"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let per = TrimController.samplesPerPeak
            let wave = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            var peaks: [Float] = []
            peaks.reserveCapacity(wave.count / per + 1)
            var i = 0
            while i < wave.count {
                var m: Int32 = 0
                for k in i..<min(i + per, wave.count) { m = max(m, abs(Int32(wave[k]))) }
                peaks.append(Float(m) / 32768)
                i += per
            }
            let result = peaks
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.wave = wave
                self.rawPeaks = result
                self.redrawWaveform()
            }
        }
    }

    nonisolated static let waveRate = 2000
    nonisolated static let samplesPerPeak = Int(Double(waveRate) / peaksPerSecond)

    /// Recompute the drawn waveform from the original: each separated
    /// section mixed in at its choice, then the volume change, fades and
    /// limiter inside the part being kept, as Save will do it.
    private func redrawWaveform() {
        guard !rawPeaks.isEmpty else { return }
        var lin = rawPeaks
        let per = Self.samplesPerPeak
        for m in sections where m.choice != .original {
            guard let file = musicFiles[m.id], let d = musicWave[file] else { continue }
            let first = samples(m).from * Self.waveRate / Int(Self.musicRate)
            let k = Float(m.choice.amount)
            let lo = max(first / per, 0), hi = min((first + d.count) / per, lin.count - 1)
            guard lo <= hi else { continue }
            for b in lo...hi {
                var top: Float = 0
                for i in b * per..<min((b + 1) * per, wave.count) {
                    var v = Float(wave[i]) / 32768
                    let j = i - first
                    if j >= 0 && j < d.count { v += k * d[j] }
                    top = max(top, abs(v))
                }
                lin[b] = top
            }
        }
        if repair, let take = repairTake, let d = musicWave[take.url] {
            let first = Int((take.from * Double(Self.waveRate)).rounded())
            let lo = max(first / per, 0), hi = min((first + d.count) / per - 1, lin.count - 1)
            if lo <= hi {
                for b in lo...hi {
                    var top: Float = 0
                    for j in max(b * per - first, 0)..<min((b + 1) * per - first, d.count) { top = max(top, abs(d[j])) }
                    lin[b] = top
                }
            }
        }
        let s = preview.settings
        if s.gain != 1 || s.fade {
            let lo = max(Int(s.start * Self.peaksPerSecond), 0)
            let hi = min(Int(s.end * Self.peaksPerSecond), lin.count - 1)
            if lo <= hi {
                for b in lo...hi {
                    let t = (Double(b) + 0.5) / Self.peaksPerSecond
                    var v = lin[b] * s.gain * Float(s.fadeLevel(t))
                    if s.gain > 1 { v = min(v, PreviewSettings.limit) }
                    lin[b] = v
                }
            }
        }
        peaks = lin.map { $0.squareRoot() }
    }

    /// Read each new separated file at 2 kHz for the waveform.
    private func loadMusicWaves() {
        let wanted = Set(musicFiles.values)
        musicWave = musicWave.filter { wanted.contains($0.key) }
        let ffmpeg = Paths.resources.appendingPathComponent("bin/ffmpeg")
        for file in wanted where musicWave[file] == nil {
            Task.detached(priority: .utility) {
                let p = Process()
                p.executableURL = ffmpeg
                p.arguments = ["-nostdin", "-loglevel", "error", "-i", file.path, "-ac", "1",
                               "-ar", "\(TrimController.waveRate)", "-f", "f32le", "-"]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                await MainActor.run { [weak self] in
                    guard let self, self.musicFiles.values.contains(file) else { return }
                    self.musicWave[file] = samples
                    self.redrawWaveform()
                }
            }
        }
        redrawWaveform()
    }

    private func loadThumbnails(_ asset: AVAsset) {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 320, height: 180)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        generator = gen
        let n = Self.thumbCount
        let times = (0..<n).map {
            CMTime(seconds: duration * (Double($0) + 0.5) / Double(n), preferredTimescale: 600)
        }
        gen.generateCGImagesAsynchronously(forTimes: times.map { NSValue(time: $0) }) {
            [weak self] requested, image, _, _, _ in
            guard let image else { return }
            let i = times.firstIndex(of: requested) ?? -1
            DispatchQueue.main.async {
                if let self, i >= 0 { self.thumbs[i] = image }
            }
        }
    }

    // MARK: playback

    private func tick(_ t: Double) {
        let isPlaying = player.rate != 0
        if playing != isPlaying { playing = isPlaying }
        if reversing != (player.rate < 0) { reversing = player.rate < 0 }
        guard isPlaying, !seeking, seekTarget == nil, t.isFinite else { return }
        let frame = snap(t)
        if frame != current { current = frame }
        if let s = stopAt, t >= s {
            let back = stopReturn
            pause()
            if let back { seek(back) }
        }
    }

    /// Show exactly the frame containing `t`. Seeks chase each other so fast
    /// scrubbing never queues up a backlog.
    func seek(_ t: Double) {
        let target = snap(t)
        current = target
        seekTarget = target
        if !seeking { performSeek() }
    }

    private func performSeek() {
        guard let t = seekTarget else { return }
        seekTarget = nil
        seeking = true
        // A quarter frame in, so rounding can never land on the previous frame.
        let ct = CMTime(seconds: t + 0.25 / fps, preferredTimescale: 600_000)
        player.seek(to: ct, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                self?.seeking = false
                self?.performSeek()
            }
        }
    }

    func play(rate: Float = 1) {
        guard ready else { return }
        stopAt = nil
        if rate > 0 && frame(current) >= lastFrame { seek(0) }
        player.rate = rate
        playing = true
        reversing = rate < 0
    }

    func pause() {
        stopAt = nil
        playingSection = nil
        let wasPlaying = player.rate != 0
        player.pause()
        playing = false
        reversing = false
        if wasPlaying { seek(player.currentTime().seconds) }
    }

    /// Space / the play button: pause if playing forward; otherwise (paused,
    /// or playing backwards) play forward.
    func togglePlay() { player.rate > 0 ? pause() : play() }

    /// J/L: each press goes faster in that direction; the other way slows/reverses.
    func shuttle(_ direction: Int) {
        stopAt = nil
        let r = player.rate
        var next: Float = direction > 0 ? (r > 0 ? min(r * 2, 8) : 1) : (r < 0 ? max(r * 2, -8) : -1)
        if next < 0 && !(player.currentItem?.canPlayReverse ?? false) { next = 0 }
        if next == 0 { pause() } else { play(rate: next) }
    }

    func step(_ frames: Int) {
        pause()
        seek(time(frame(current) + frames))
    }

    func playFromIn() {
        pause()
        seek(inPoint)
        play()
    }

    /// Play the last few seconds up to and including the end frame, then stop on it.
    func playToOut() {
        pause()
        seek(max(inPoint, outPoint - 3))
        play()
        stopAt = outPoint + frameDuration
        stopReturn = outPoint
    }

    /// From a couple of seconds before a music section to a second after it.
    func playSection(_ id: UUID) {
        guard let m = sections.first(where: { $0.id == id }) else { return }
        activeSection = id
        pause()
        seek(max(m.from - 2, 0))
        play()
        stopAt = m.to + frameDuration + 1
        stopReturn = nil
        playingSection = id
    }

    // MARK: start / end

    func setIn(_ t: Double) {
        let f = min(max(frame(snap(t)), 0), frame(outPoint) - 1)
        inPoint = time(max(f, 0))
        onChange?()
        updatePreview()
        keptPartChanged()
    }

    func setOut(_ t: Double) {
        let f = max(min(frame(snap(t)), lastFrame), frame(inPoint) + 1)
        outPoint = time(min(f, lastFrame))
        onChange?()
        updatePreview()
        keptPartChanged()
    }

    func markIn() {
        if frame(current) >= frame(outPoint) { NSSound.beep(); return }
        setIn(current)
    }

    func markOut() {
        if frame(current) <= frame(inPoint) { NSSound.beep(); return }
        setOut(current)
    }

    func nudgeIn(_ frames: Int) {
        setIn(time(frame(inPoint) + frames))
        pause()
        seek(inPoint)
    }

    func nudgeOut(_ frames: Int) {
        setOut(time(frame(outPoint) + frames))
        pause()
        seek(outPoint)
    }

    // MARK: suggestions

    func loadSuggestions(_ s: TrimSuggestions?) {
        pendingSuggestions = s
        startPick = 0
        endPick = 0
        checkSuggestions()
    }

    private var pendingSuggestions: TrimSuggestions?

    /// Drop suggestions made for a different video with the same name.
    private func checkSuggestions() {
        guard ready else { return }
        if let d = pendingSuggestions?.duration, abs(d - duration) > 2 {
            suggestions = nil
        } else {
            suggestions = pendingSuggestions
        }
    }

    var suggestedStart: TrimSuggestion? { suggestions?.starts[safe: startPick] }
    var suggestedEnd: TrimSuggestion? { suggestions?.ends[safe: endPick] }

    /// With the fade on, the suggested cut leaves the fade room in the pause
    /// (as Jacob cuts it); with it off, or where an intro or outro takes its
    /// place, half a second from his voice at most.
    func startTime(_ s: TrimSuggestion) -> Double {
        fade && intro == nil ? s.time : max(s.time, s.word - min(0.5, (s.word - s.room) * 0.6))
    }
    func endTime(_ s: TrimSuggestion) -> Double {
        fade && outro == nil ? s.time : min(s.time, s.word + min(0.5, (s.room - s.word) * 0.6))
    }

    func useStart(_ s: TrimSuggestion) {
        pause()
        setIn(startTime(s))
        seek(inPoint)
    }

    func useEnd(_ s: TrimSuggestion) {
        pause()
        setOut(endTime(s))
        seek(outPoint)
    }

    /// Play from exactly the suggested spot.
    /// ▶ on a suggestion: from exactly the suggested spot, or (the other
    /// setting) a few seconds either side of it, stopping back on the spot.
    func hearStart(_ s: TrimSuggestion, around: Bool) {
        pause()
        if around {
            seek(max(startTime(s) - 3, 0))
            play()
            stopAt = s.word + 5
            stopReturn = snap(startTime(s))
        } else {
            seek(startTime(s))
            play()
        }
    }

    func hearEnd(_ s: TrimSuggestion, around: Bool) {
        pause()
        if around {
            seek(max(s.word - 6, 0))
            play()
            stopAt = endTime(s) + 3
            stopReturn = snap(endTime(s))
        } else {
            seek(endTime(s))
            play()
        }
    }

    // MARK: auto color

    /// The colour is measured on the part being kept (worship lighting before
    /// the sermon would skew it), so a real change to start or end means
    /// measuring again; small nudges don't.
    private var colorKey: String { "\(Int(inPoint / 30))-\(Int(outPoint / 30))" }

    private func colorChanged() {
        if autoColor {
            colorTask?.cancel()
            colorTask = Task { await measureColor() }
        } else {
            applyLook()
        }
    }

    /// Start or end moved: measure the colour and loudness again if it moved
    /// far enough to matter (after the dragging settles).
    private func keptPartChanged() {
        guard ready else { return }
        if autoColor, color?.key != colorKey {
            colorTask?.cancel()
            colorTask = Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { return false }
                return await measureColor()
            }
        }
        refreshMusic()   // a repair may no longer cover the part being kept
        if level, loudness?.key != levelKey {
            levelTask?.cancel()
            levelTask = Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { return false }
                return await measureLevel()
            }
        }
    }

    /// The Auto color table for the current kept part, measuring it if
    /// needed. False if it couldn't be measured.
    func ensureColor() async -> Bool {
        if color?.key == colorKey { return true }
        if let task = colorTask, await task.value, color?.key == colorKey { return true }
        return await measureColor()
    }

    private func measureColor() async -> Bool {
        guard ready else { return false }
        let key = colorKey
        if color?.key == key {
            applyLook()
            return true
        }
        colorBusy = true
        defer { colorBusy = false }
        guard let measured = await AutoColor.measure(asset, from: inPoint, to: outPoint + frameDuration),
              !Task.isCancelled else { return false }
        let table = AutoColor.table(measured.look, space: measured.space)
        let file = Paths.colorCache.appendingPathComponent("\(sourceKey) \(key).cube")
        do {
            try FileManager.default.createDirectory(at: Paths.colorCache, withIntermediateDirectories: true)
            try AutoColor.cube(table).write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        color = (key, table.withUnsafeBufferPointer { Data(buffer: $0) }, measured.space, file)
        applyLook()
        return true
    }

    /// Show the picture with Auto color and the fades (or without), live.
    private func applyLook() {
        guard let item = player.currentItem else { return }
        let table = autoColor ? color.map { ($0.table, $0.space) } : nil
        guard table != nil || fade else {
            item.videoComposition = nil
            return
        }
        let state = preview
        item.videoComposition = AVVideoComposition(asset: item.asset) { request in
            let cube = table.flatMap { AutoColor.filter($0.0, space: $0.1) }
            request.finish(with: previewFrame(request.sourceImage, at: request.compositionTime.seconds,
                                              state: state, cube: cube), context: nil)
        }
    }

    // MARK: fades and volume

    private func updatePreview() {
        let start = exportStart, end = exportStart + exportLength
        let gain = level ? Float(pow(10, (loudness?.gainDB ?? 0) / 20)) : 1
        let fade = fade, fadeIn = intro == nil, fadeOut = outro == nil
        preview.update {
            $0.fade = fade
            $0.fadeIn = fadeIn
            $0.fadeOut = fadeOut
            $0.start = start
            $0.end = end
            $0.gain = gain
        }
        redrawWaveform()
    }

    /// "Even out the volume" brings the part being kept to -16 LUFS (the
    /// usual online level) with one fixed change, so it can be heard live.
    static let targetLoudness = -16.0

    private func levelChanged() {
        if level {
            levelTask?.cancel()
            levelTask = Task { await measureLevel() }
        } else {
            levelGain = nil
            updatePreview()
        }
    }

    /// The volume change for the current kept part, measuring it if needed.
    /// What the loudness was measured on: the kept part, original or repaired.
    private var levelKey: String {
        colorKey + (repair ? " " + (repairTake?.url.lastPathComponent ?? "repair pending") : "")
    }

    func ensureLevel() async -> Bool {
        if loudness?.key == levelKey { return true }
        if let task = levelTask, await task.value, loudness?.key == levelKey { return true }
        return await measureLevel()
    }

    private func measureLevel() async -> Bool {
        guard ready else { return false }
        let key = levelKey
        if loudness?.key != key {
            levelBusy = true
            defer { levelBusy = false }
            let source: (URL, Double) = repair ? (repairTake.map { ($0.url, exportStart - $0.from) } ?? (url, exportStart))
                                               : (url, exportStart)
            guard let lufs = await measureLoudness(source.0, start: source.1, length: exportLength,
                                                   dualMono: repair && repairTake != nil),
                  !Task.isCancelled else { return false }
            loudness = (key, min(max(Self.targetLoudness - lufs, -12), 18))
        }
        if level { levelGain = loudness?.gainDB }
        updatePreview()
        return true
    }

    /// The volume change in dB for `sermon_captions.py trim`, or "-" for none.
    var levelArg: String {
        guard level, let g = loudness?.gainDB else { return "-" }
        return String(format: "%.2f", g)
    }

    /// The .cube file for `sermon_captions.py trim`, or "-" for none.
    var colorArg: String { autoColor ? (color?.file.path ?? "-") : "-" }

    // MARK: intro and outro

    /// Use (or with nil, take off) an intro or outro the user picked.
    /// Returns why not, if the file can't be used.
    func chooseClip(_ slot: ClipSlot, _ url: URL?, remember: Bool = true) async -> String? {
        guard ready else { return nil }
        clipPicks[slot, default: 0] += 1
        let pick = clipPicks[slot]
        var clip: Clip?
        if let url {
            let d = await Self.clipLength(url)
            guard clipPicks[slot] == pick, !closed else { return nil }   // a later pick (or video) took its place
            guard let d else { return "Couldn't read the video in \(url.lastPathComponent)." }
            clip = Clip(url: url, duration: d)
        }
        setClip(slot, clip)
        clipNote = nil
        if remember { UserDefaults.standard.set(url?.path, forKey: slot.defaultsKey) }
        onChange?()
        return nil
    }

    /// Counts each slot's picks, so a slow one can't land after a newer one.
    private var clipPicks: [ClipSlot: Int] = [:]

    private func setClip(_ slot: ClipSlot, _ clip: Clip?) {
        switch slot {
        case .intro: intro = clip
        case .outro: outro = clip
        }
        updatePreview()   // that end of the sermon stops (or starts) fading
    }

    /// How long a video's picture runs, or nil if it has none.
    nonisolated static func clipLength(_ url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let range = try? await track.load(.timeRange) else { return nil }
        let d = range.end.seconds
        return d.isFinite && d > 0 ? d : nil
    }

    /// Extra arguments for `sermon_captions.py trim`.
    var clipArgs: [String] {
        (intro.map { ["--intro", $0.url.path] } ?? []) + (outro.map { ["--outro", $0.url.path] } ?? [])
    }

    // MARK: repair

    /// The repaired voice's track in the player (alongside the music sections').
    nonisolated static let repairID = UUID(uuidString: "00000000-0000-0000-0000-00000000AE01")!

    /// The music choices a repair of from..to mixes in: every non-Original
    /// separated section that overlaps it (not just the kept part, so moving
    /// the start across a section doesn't throw away a repair that covers it).
    func repairMusicArgs(from: Double, to: Double, files: [UUID: URL]) -> [String] {
        sections.flatMap { m -> [String] in
            guard m.choice != .original, m.to >= from, m.from <= to, let file = files[m.id] else { return [] }
            return [file.path, "\(samples(m).from)", String(format: "%.4f", m.choice.amount)]
        }
    }

    /// A repair covers the music choices it was made with; a different
    /// choice means repairing again.
    func repairSignature(from: Double, to: Double, files: [UUID: URL]) -> String {
        SHA256.hash(data: Data(repairMusicArgs(from: from, to: to, files: files).joined(separator: "|").utf8))
            .prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// The span to repair for the current start and end: 30 s extra each
    /// side, so small changes afterwards don't need a new repair.
    var repairSpan: (from: Double, to: Double) {
        let from = (max(exportStart - 30, 0) * 1000).rounded() / 1000
        let to = (min(exportStart + exportLength + 30, duration) * 1000).rounded() / 1000
        return (from, to)
    }

    func repairPath(from: Double, to: Double) -> URL {
        Paths.repairCache.appendingPathComponent("\(sourceKey) \(Int((from * 1000).rounded()))-"
            + "\(Int((to * 1000).rounded())) \(repairSignature(from: from, to: to, files: musicFiles)).wav")
    }

    /// A finished repair that covers the part being kept, made with the
    /// music choices (given by `files`, the separated audio) as they are now.
    private func findRepair(files: [UUID: URL]) -> RepairTake? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Paths.repairCache.path)) ?? []
        for name in names where name.hasPrefix(sourceKey + " ") && name.hasSuffix(".wav") {
            let parts = name.dropFirst(sourceKey.count + 1).dropLast(4).split(separator: " ")
            guard parts.count == 2 else { continue }
            let span = parts[0].split(separator: "-")
            guard span.count == 2, let a = Double(span[0]), let b = Double(span[1]) else { continue }
            let from = a / 1000, to = b / 1000
            if from <= exportStart + 0.001 && to >= exportStart + exportLength - 0.001
                && parts[1] == repairSignature(from: from, to: to, files: files) {
                return RepairTake(url: Paths.repairCache.appendingPathComponent(name), from: from, to: to)
            }
        }
        return nil
    }

    /// Repair the voice is on but there's no repair that fits yet.
    var repairNeeded: Bool { repair && repairTake == nil }

    /// Whether the player is playing the repaired voice right now.
    private var repairing: Bool { repair && repairTake != nil && musicTracks[Self.repairID] != nil }

    /// The music choices to mix into a new repair of `repairSpan`.
    var repairJobMusicArgs: [String] {
        let span = repairSpan
        return repairMusicArgs(from: span.from, to: span.to, files: musicFiles)
    }

    var repairArgs: [String] {
        guard repair, let t = repairTake else { return [] }
        return ["--repair", t.url.path, String(format: "%.3f", t.from)]
    }

    // MARK: music

    nonisolated static let musicRate = 48000.0

    /// A new section from the playhead, 30 seconds long or up to the next
    /// one. Returns why not, if it can't.
    @discardableResult
    func addSection() -> String? {
        let f = frame(current)
        if let inside = sections.first(where: { frame($0.from) <= f && f <= frame($0.to) }) {
            activeSection = inside.id
            return "The playhead is already inside a music section. Move it to where the music starts first."
        }
        let limit = sections.first { frame($0.from) > f }.map { frame($0.from) - 1 } ?? lastFrame
        let end = min(f + Int(30 * fps), limit)
        guard end - f >= minSectionFrames else {
            return "There's less than a second before the next music section (or the end). Move the playhead earlier."
        }
        // Same treatment as the last one changed, which is usually what's wanted.
        let choice = sections.first { $0.id == activeSection }?.choice ?? .original
        let m = MusicSection(from: time(f), to: time(end), choice: choice)
        sections.append(m)
        sections.sort { $0.from < $1.from }
        activeSection = m.id
        musicChanged()
        return nil
    }

    /// Move a section's start (or end) to the playhead, keeping it at least
    /// a second long and clear of its neighbours.
    func setSectionStart(_ id: UUID) {
        guard let i = sections.firstIndex(where: { $0.id == id }) else { return }
        let f = frame(current)
        let floor = i > 0 ? frame(sections[i - 1].to) + 1 : 0
        guard f >= floor, frame(sections[i].to) - f >= minSectionFrames else { NSSound.beep(); return }
        sections[i].from = time(f)
        activeSection = id
        musicChanged()
    }

    func setSectionEnd(_ id: UUID) {
        guard let i = sections.firstIndex(where: { $0.id == id }) else { return }
        let f = frame(current)
        let ceiling = i + 1 < sections.count ? frame(sections[i + 1].from) - 1 : lastFrame
        guard f <= ceiling, f - frame(sections[i].from) >= minSectionFrames else { NSSound.beep(); return }
        sections[i].to = time(f)
        activeSection = id
        musicChanged()
    }

    func removeSection(_ id: UUID) {
        sections.removeAll { $0.id == id }
        if activeSection == id { activeSection = nil }
        musicChanged()
    }

    func setChoice(_ id: UUID, _ choice: MusicChoice) {
        guard let i = sections.firstIndex(where: { $0.id == id }) else { return }
        sections[i].choice = choice
        activeSection = id
        applyMix()
        redrawWaveform()
        onChange?()
        refreshMusic()   // a repair made with the old choice no longer fits
    }

    /// The 1 2 3 keys: the section being played, else the one under the
    /// playhead, else the only one. Anywhere else they do nothing (and beep).
    func setChoiceHere(_ choice: MusicChoice) -> Bool {
        let f = frame(current)
        guard let id = playingSection
                ?? sections.first(where: { frame($0.from) <= f && f <= frame($0.to) })?.id
                ?? (sections.count == 1 ? sections[0].id : nil) else { return false }
        setChoice(id, choice)
        return true
    }

    private var minSectionFrames: Int { Int(fps.rounded(.up)) }

    private func musicChanged() {
        onChange?()
        refreshMusic()
    }

    /// A section in samples at 48 kHz, through the end of its last frame.
    func samples(_ m: MusicSection) -> (from: Int, to: Int) {
        (Int((m.from * Self.musicRate).rounded()), Int(((m.to + frameDuration) * Self.musicRate).rounded()))
    }

    /// Separated audio is named by video and section, so a section that has
    /// moved never plays or saves audio separated for a different one.
    func musicPath(_ m: MusicSection) -> URL {
        let s = samples(m)
        return Paths.musicCache.appendingPathComponent("\(sourceKey) \(s.from)-\(s.to).wav")
    }

    /// Changes if the video is replaced by a different file with the same name.
    lazy var sourceKey: String = {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let id = "\(url.standardizedFileURL.path)|\(v?.fileSize ?? 0)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        return SHA256.hash(data: Data(id.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }()

    var unseparated: [MusicSection] { sections.filter { musicFiles[$0.id] == nil } }

    /// A choice other than Original that can't be heard or saved yet.
    var musicNeedsSeparating: Bool {
        sections.contains { $0.choice != .original && musicFiles[$0.id] == nil && !outsideTrim($0) }
    }

    /// The section doesn't overlap the part being kept.
    func outsideTrim(_ m: MusicSection) -> Bool { m.to < inPoint || m.from > outPoint }

    /// Pick up the separated audio for each section (or lose it when a
    /// section moves) and rebuild what the player plays to match.
    func refreshMusic() {
        var files: [UUID: URL] = [:]
        for m in sections where FileManager.default.fileExists(atPath: musicPath(m).path) {
            files[m.id] = musicPath(m)
        }
        guard ready else { return }
        // The repaired voice rides along as one more track, so switching is instant.
        let take = findRepair(files: files)
        if take?.url != repairTake?.url {
            repairTake = take
            if level { levelChanged() }
        }
        if let take { files[Self.repairID] = take.url }
        guard files != musicFiles || files != builtFor else { return }
        builtFor = files
        musicFiles = files
        loadMusicWaves()
        let asset = asset
        var parts = sections.compactMap { m in files[m.id].map { (id: m.id, url: $0, at: samples(m).from) } }
        if let take { parts.append((id: Self.repairID, url: take.url, at: Int((take.from * Self.musicRate).rounded()))) }
        itemBuild?.cancel()
        itemBuild = Task { [weak self] in
            var built: (comp: AVComposition, tracks: [UUID: CMPersistentTrackID], sound: CMPersistentTrackID?, lined: Bool)?
            if !parts.isEmpty { built = await Self.composition(asset, music: parts) }
            guard let self, !Task.isCancelled, self.musicFiles == files else { return }
            if parts.isEmpty {
                self.musicPreviewNote = nil
            } else if let built {
                self.musicPreviewNote = built.lined ? nil
                    : "The preview might not line up exactly with this video, so it can sound a little off. The saved video will be right."
            } else {
                self.musicPreviewNote = "Couldn't set up the preview for this video. Saving still works."
            }
            self.swapItem(built.map { AVPlayerItem(asset: $0.comp) } ?? AVPlayerItem(asset: asset),
                          tracks: built?.tracks ?? [:], sound: built.map { $0.sound } ?? self.assetSoundTrack)
        }
    }

    /// The video and its sound, plus each section's separated audio as its
    /// own track, so switching choices is just that track's volume.
    /// `lined` is false if the player's offset from ffmpeg couldn't be measured.
    nonisolated private static func composition(_ asset: AVURLAsset, music: [(id: UUID, url: URL, at: Int)]) async
        -> (comp: AVComposition, tracks: [UUID: CMPersistentTrackID], sound: CMPersistentTrackID?, lined: Bool)? {
        do {
            let comp = AVMutableComposition()
            let video = try await asset.loadTracks(withMediaType: .video).prefix(1)
            let audio = try await asset.loadTracks(withMediaType: .audio).prefix(1)
            var sound: CMPersistentTrackID?
            for track in video + audio {
                let range = try await track.load(.timeRange)
                guard let t = comp.addMutableTrack(withMediaType: track.mediaType,
                                                   preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
                try t.insertTimeRange(range, of: track, at: range.start)
                t.preferredTransform = try await track.load(.preferredTransform)
                if track.mediaType == .audio { sound = t.trackID }
            }
            // The offset is the same all through a file; any section's reference will do.
            // Measured separately for the repaired voice: its reference is
            // placed by time, the sections' by sample count.
            var offset: Int?, repairOffset: Int?
            if let original = audio.first {
                for m in music where m.id != repairID && offset == nil {
                    offset = await playerOffset(asset, original, ref: URL(fileURLWithPath: m.url.path + ".ref"))
                }
                if let r = music.first(where: { $0.id == repairID }) {
                    repairOffset = await playerOffset(asset, original, ref: URL(fileURLWithPath: r.url.path + ".ref"))
                }
            }
            var tracks: [UUID: CMPersistentTrackID] = [:]
            for m in music {
                // Keep the asset alive: a track doesn't hold on to its asset.
                let musicAsset = AVURLAsset(url: m.url)
                guard let source = try await musicAsset.loadTracks(withMediaType: .audio).first,
                      let t = comp.addMutableTrack(withMediaType: .audio,
                                                   preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
                var at = m.at - ((m.id == repairID ? repairOffset ?? offset : offset) ?? 0)
                // A section from the very start can land before 0: drop what would.
                var range = try await source.load(.timeRange)
                if at < 0 {
                    let skip = CMTime(value: CMTimeValue(-at), timescale: CMTimeScale(musicRate))
                    range = CMTimeRange(start: range.start + skip, duration: range.duration - skip)
                    at = 0
                }
                try t.insertTimeRange(range, of: source, at: CMTime(value: CMTimeValue(at),
                                                                    timescale: CMTimeScale(musicRate)))
                withExtendedLifetime(musicAsset) {}
                tracks[m.id] = t.trackID
            }
            return (comp, tracks, sound, offset != nil)
        } catch {
            return nil
        }
    }

    /// How many samples ahead of ffmpeg AVFoundation's decode of `track` runs.
    /// The separated audio only cancels the music if it lines up to the
    /// sample, and the two disagree on some files (by 2112 samples on an
    /// iMovie export). Found by matching the reference second the separate
    /// step saved against AVFoundation's own decode around the same spot.
    nonisolated private static func playerOffset(_ asset: AVAsset, _ track: AVAssetTrack, ref: URL) async -> Int? {
        guard let data = try? Data(contentsOf: ref), data.count > 8 + 4 * 4800 else { return nil }
        let (pos, want): (Int, [Float]) = data.withUnsafeBytes { raw in
            (Int(Int64(littleEndian: raw.loadUnaligned(as: Int64.self))),
             (0..<(data.count - 8) / 4).map { raw.loadUnaligned(fromByteOffset: 8 + $0 * 4, as: Float.self) })
        }
        let search = 9600   // ±0.2 s
        let from = max(pos - search, 0)
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        reader.timeRange = CMTimeRange(start: CMTime(value: CMTimeValue(from), timescale: CMTimeScale(musicRate)),
                                       duration: CMTime(value: CMTimeValue(want.count + 2 * search),
                                                        timescale: CMTimeScale(musicRate)))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: musicRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false])
        reader.add(out)
        guard reader.startReading() else { return nil }
        var got: [Float] = []
        var first: Int?
        while let sb = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            if first == nil {
                first = Int(CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sb),
                                               timescale: CMTimeScale(musicRate), method: .roundHalfAwayFromZero).value)
            }
            var chunk = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            guard chunk.withUnsafeMutableBytes({
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }) == noErr else { return nil }
            got += chunk
        }
        guard let first, got.count > want.count else { return nil }
        // result[n] = Σ want[k] · got[n + k]: the best n is where the reference sits.
        let count = got.count - want.count + 1
        var result = [Float](repeating: 0, count: count)
        vDSP_conv(got, 1, want, 1, &result, 1, vDSP_Length(count), vDSP_Length(want.count))
        var peak: Float = 0
        var n: vDSP_Length = 0
        vDSP_maxvi(result, 1, &peak, &n, vDSP_Length(count))
        // Only trust a clear match.
        var e1: Float = 0, e2: Float = 0
        vDSP_svesq(want, 1, &e1, vDSP_Length(want.count))
        got.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + Int(n), 1, &e2, vDSP_Length(want.count)) }
        guard e1 > 0, e2 > 0, peak / (e1 * e2).squareRoot() > 0.5 else { return nil }
        return pos - (first + Int(n))
    }

    /// Every sound track gets the preview tap (fades and volume); each
    /// section's separated audio is added at its choice's amount.
    private func applyMix() {
        guard let item = player.currentItem else { return }
        var params: [AVMutableAudioMixInputParameters] = []
        // With the repair on, the repaired voice (which has the music choices
        // in it) plays instead of the original and the music corrections.
        let span = repairing ? repairTake : nil
        // AVFoundation slides linearly between volume settings rather than
        // switching at them, so hold each level with a second point and make
        // the change a quick 10 ms one. (With just "0 at from, 1 at to" the
        // original faded back in across the whole repaired stretch.)
        func setVolume(_ p: AVMutableAudioMixInputParameters, _ v: Float) {
            let at = { (t: Double) in CMTime(seconds: max(t, 0), preferredTimescale: 48000) }
            p.setVolume(v, at: .zero)
            if let span {
                if span.from > 0.01 { p.setVolume(v, at: at(span.from - 0.01)) }
                p.setVolume(0, at: at(span.from))
                p.setVolume(0, at: at(span.to))
                p.setVolume(v, at: at(span.to + 0.01))
            }
        }
        if let soundTrack {
            let p = AVMutableAudioMixInputParameters()
            p.trackID = soundTrack
            setVolume(p, 1)
            params.append(p)
        }
        for m in sections {
            guard let id = musicTracks[m.id] else { continue }
            let p = AVMutableAudioMixInputParameters()
            p.trackID = id
            setVolume(p, Float(m.choice.amount))
            params.append(p)
        }
        if let id = musicTracks[Self.repairID] {
            let p = AVMutableAudioMixInputParameters()
            p.trackID = id
            p.setVolume(span == nil ? 0 : 1, at: .zero)
            params.append(p)
        }
        for p in params { p.audioTapProcessor = makePreviewTap(preview) }
        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        item.audioMix = mix
    }

    /// Extra arguments for `sermon_captions.py trim`: each changed section.
    var musicArgs: [String] {
        sections.flatMap { m -> [String] in
            guard m.choice != .original, !outsideTrim(m), let file = musicFiles[m.id] else { return [] }
            return [file.path, "\(samples(m).from)", String(format: "%.4f", m.choice.amount)]
        }
    }

    /// Arguments for `sermon_captions.py separate`: each section not done yet.
    var separateArgs: [String] {
        unseparated.flatMap { m in ["\(samples(m).from)", "\(samples(m).to)", musicPath(m).path] }
    }

    var points: TrimPoints {
        TrimPoints(inTime: inPoint, outTime: outPoint, fade: fade, level: level, musicSections: sections,
                   autoColor: autoColor, repair: repair, intro: intro?.url.path, outro: outro?.url.path)
    }

    /// Arguments for `sermon_captions.py trim`: start a quarter frame early and
    /// stop half a frame short so ffmpeg keeps exactly the chosen frames.
    var exportStart: Double { max(inPoint - 0.25 / fps, 0) }
    var exportLength: Double { (Double(keptFrames) - 0.5) / fps }

    func timecode(_ t: Double) -> String {
        let f = frame(t)
        let whole = Int((Double(f) / fps).rounded(.down))
        let within = f - Int((Double(whole) * fps).rounded(.up))
        return String(format: "%d:%02d:%02d;%02d", whole / 3600, whole / 60 % 60, whole % 60, max(within, 0))
    }
}

// MARK: - Views

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

/// A timeline over `range`. Drag anywhere to scrub; grab the green or red
/// marker to move the start or end.
struct ScrubBar: View {
    @ObservedObject var c: TrimController
    let range: ClosedRange<Double>
    var thumbnails = false
    var ticks = false
    var onDrag: (Bool) -> Void = { _ in }
    /// Where the bar is in the window, for scrolling over it.
    var onFrame: (CGRect) -> Void = { _ in }
    /// While playing, the player's own (smooth) time for the playhead.
    var now: Double?

    private enum Grab { case playhead, start, end }
    @State private var grab: Grab?
    @State private var dragStart: CGPoint?
    /// Resets on its own when a drag ends or is cancelled.
    @GestureState private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                Canvas { ctx, size in drawBackground(ctx, size) }
                Canvas { ctx, size in drawMarks(ctx, size) }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { v in drag(v, width: w) }
            )
            .onChange(of: dragging) { _, now in
                if !now {
                    grab = nil
                    dragStart = nil
                    onDrag(false)
                }
            }
            .onAppear { onFrame(geo.frame(in: .global)) }
            .onChange(of: geo.frame(in: .global)) { _, frame in onFrame(frame) }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var span: Double { max(range.upperBound - range.lowerBound, 0.001) }
    private func x(_ t: Double, _ w: CGFloat) -> CGFloat { CGFloat((t - range.lowerBound) / span) * w }
    private func t(_ x: CGFloat, _ w: CGFloat) -> Double { range.lowerBound + Double(x / max(w, 1)) * span }

    private func drag(_ v: DragGesture.Value, width w: CGFloat) {
        guard c.ready else { return }
        if grab == nil || dragStart != v.startLocation {
            dragStart = v.startLocation
            onDrag(true)
            let sx = v.startLocation.x
            let dIn = abs(sx - x(c.inPoint, w))
            let dOut = abs(sx - x(c.outPoint + c.frameDuration, w))
            grab = min(dIn, dOut) > 8 ? .playhead : (dIn <= dOut ? .start : .end)
            c.pause()
        }
        let time = min(max(t(v.location.x, w), 0), c.duration)
        switch grab {
        case .start:
            c.setIn(time)
            c.seek(c.inPoint)
        case .end:
            c.setOut(time - c.frameDuration)
            c.seek(c.outPoint)
        default:
            c.seek(time)
        }
    }

    private func drawBackground(_ ctx: GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        var waveTop: CGFloat = 0
        if thumbnails {
            let th = h * 0.58
            let tw = th * 16 / 9
            let count = max(Int(w / tw), 1)
            for i in 0..<count {
                let mid = range.lowerBound + (Double(i) + 0.5) * span / Double(count)
                let idx = min(max(Int(mid / max(c.duration, 0.001) * Double(TrimController.thumbCount)), 0),
                              TrimController.thumbCount - 1)
                let rect = CGRect(x: CGFloat(i) * w / CGFloat(count), y: 0, width: w / CGFloat(count) - 1, height: th)
                if let img = c.thumbs[idx] {
                    ctx.draw(Image(decorative: img, scale: 1), in: rect)
                } else {
                    ctx.fill(Path(rect), with: .color(.gray.opacity(0.15)))
                }
            }
            waveTop = th + 2
        }
        if ticks {
            drawTicks(ctx, size)
            waveTop = 16
        }
        // Waveform, centred in the space left over.
        let peaks = c.peaks
        guard !peaks.isEmpty else { return }
        let mid = (waveTop + h) / 2, amp = (h - waveTop) / 2 - 2
        var path = Path()
        // Bars about 2 px wide, on a grid fixed in time rather than on the
        // screen: as the close-up slides, each bar keeps its height and moves
        // with the sound instead of being re-sampled (which made them shimmer).
        let step: CGFloat = 2
        let pps = TrimController.peaksPerSecond
        let peaksPerBar = max(Int((Double(step) * span / Double(max(w, 1)) * pps).rounded()), 1)
        let barSeconds = Double(peaksPerBar) / pps
        let barWidth = max(x(range.lowerBound + barSeconds, w) - x(range.lowerBound, w), 1)
        var k = Int((range.lowerBound * pps).rounded(.down)) / peaksPerBar * peaksPerBar
        while Double(k) / pps < range.upperBound {
            if k + peaksPerBar > 0 && k < peaks.count {
                var m: Float = 0
                for i in max(k, 0)..<min(k + peaksPerBar, peaks.count) { m = max(m, peaks[i]) }
                let bar = max(CGFloat(m) * amp, 0.5)
                path.addRect(CGRect(x: x(Double(k) / pps, w), y: mid - bar, width: max(barWidth - 0.5, 0.5),
                                    height: bar * 2))
            }
            k += peaksPerBar
        }
        ctx.fill(path, with: .color(Color(red: 0.45, green: 0.7, blue: 1).opacity(0.85)))
    }

    private func drawTicks(_ ctx: GraphicsContext, _ size: CGSize) {
        let w = size.width
        let pxPerSecond = w / CGFloat(span)
        // Smallest label step that keeps labels ~70px apart.
        let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300]
        let labelStep = steps.first { CGFloat($0) * pxPerSecond >= 70 } ?? 600
        var tick = Path()
        var s = (range.lowerBound).rounded(.down)
        while s <= range.upperBound {
            let px = x(s, w)
            tick.move(to: CGPoint(x: px, y: 0))
            tick.addLine(to: CGPoint(x: px, y: s.truncatingRemainder(dividingBy: labelStep) == 0 ? 10 : 5))
            if s >= 0 && s.truncatingRemainder(dividingBy: labelStep) == 0 {
                let whole = Int(s)
                ctx.draw(Text(String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60))
                            .font(.system(size: 9).monospacedDigit()).foregroundColor(.secondary),
                         at: CGPoint(x: px + 3, y: 8), anchor: .leading)
            }
            s += 1
        }
        // Individual frames once they're far enough apart to see.
        if pxPerSecond / CGFloat(c.fps) >= 6 {
            var f = c.frame(max(range.lowerBound, 0))
            while c.time(f) <= range.upperBound {
                let px = x(c.time(f), w)
                tick.move(to: CGPoint(x: px, y: size.height - 4))
                tick.addLine(to: CGPoint(x: px, y: size.height))
                f += 1
            }
        }
        ctx.stroke(tick, with: .color(.secondary.opacity(0.7)), lineWidth: 1)
    }

    private func drawMarks(_ ctx: GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        guard c.ready else { return }
        // Where "Suggest start and end" suggests, until that suggestion is used.
        for (s, color, start) in [(c.suggestedStart, Color.green, true), (c.suggestedEnd, Color.red, false)] {
            guard let s else { continue }
            let t = start ? c.startTime(s) : c.endTime(s)
            if c.frame(t) == c.frame(start ? c.inPoint : c.outPoint) { continue }
            let px = x(t, w)
            guard px >= -60 && px <= w + 60 else { continue }
            var tri = Path()
            tri.move(to: CGPoint(x: px - 6, y: 0))
            tri.addLine(to: CGPoint(x: px + 6, y: 0))
            tri.addLine(to: CGPoint(x: px, y: 10))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(color.opacity(0.9)))
            if ticks {
                var line = Path()
                line.move(to: CGPoint(x: px, y: 10))
                line.addLine(to: CGPoint(x: px, y: h))
                ctx.stroke(line, with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                let label = Text(start ? "Suggested start" : "Suggested end")
                    .font(.system(size: 9, weight: .semibold)).foregroundColor(.black)
                let resolved = ctx.resolve(label)
                let size = resolved.measure(in: CGSize(width: 200, height: 20))
                let box = CGRect(x: start ? px + 4 : px - size.width - 12, y: 18, width: size.width + 8, height: size.height + 2)
                ctx.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(color.opacity(0.85)))
                ctx.draw(resolved, at: CGPoint(x: box.midX, y: box.midY))
            }
        }
        for m in c.sections {
            let ax = x(m.from, w), bx = x(m.to + c.frameDuration, w)
            if bx >= 0 && ax <= w {
                ctx.fill(Path(CGRect(x: ax, y: 0, width: bx - ax, height: h)), with: .color(.purple.opacity(0.22)))
                ctx.fill(Path(CGRect(x: ax, y: 0, width: bx - ax, height: 5)), with: .color(.purple))
            }
        }
        let inX = x(c.inPoint, w), outX = x(c.outPoint + c.frameDuration, w)
        let shade = Color.black.opacity(0.6)
        if inX > 0 { ctx.fill(Path(CGRect(x: 0, y: 0, width: inX, height: h)), with: .color(shade)) }
        if outX < w { ctx.fill(Path(CGRect(x: outX, y: 0, width: w - outX, height: h)), with: .color(shade)) }

        for (px, color, label, leading) in [(inX, Color.green, "START", true), (outX, Color.red, "END", false)]
        where px >= -20 && px <= w + 20 {
            ctx.fill(Path(CGRect(x: px - 1.5, y: 0, width: 3, height: h)), with: .color(color))
            let flag = CGRect(x: leading ? px : px - 38, y: h - 14, width: 38, height: 14)
            ctx.fill(Path(roundedRect: flag, cornerRadius: 3), with: .color(color))
            ctx.draw(Text(label).font(.system(size: 9, weight: .bold)).foregroundColor(.black),
                     at: CGPoint(x: flag.midX, y: flag.midY))
        }

        // Playhead: the whole frame's width when zoomed in far enough.
        let at = now ?? c.current
        let px = x(at, w), fw = max(x(at + c.frameDuration, w) - px, 0)
        let ph = fw >= 3 ? CGRect(x: px, y: 0, width: fw, height: h) : CGRect(x: px - 1, y: 0, width: 2, height: h)
        ctx.fill(Path(ph), with: .color(.yellow.opacity(fw >= 3 ? 0.55 : 1)))
        ctx.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: h)), with: .color(.yellow))
    }
}

struct TrimEditor: View {
    static let title = "Trim Video"
    @ObservedObject var model: Model
    @ObservedObject var c: TrimController
    @State private var zoom = 30.0
    @State private var frozen: ClosedRange<Double>?
    @State private var monitor: Any?
    @State private var scrollMonitor: Any?
    @State private var zones = TimelineZones()
    /// What ▶ on a suggestion plays (remembered between runs).
    @AppStorage("suggestionPlaysAround") private var playAround = false
    @AppStorage(Model.captionsWithTrimKey) private var captionsWithTrim = true
    /// The intro or outro being watched in its popover.
    @State private var watching: ClipSlot?

    private func detailRange(_ now: Double?) -> ClosedRange<Double> {
        let at = now ?? c.current
        return frozen ?? (at - zoom / 2)...(at + zoom / 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PlayerView(player: c.player)
                .background(Color.black)
                .frame(minHeight: 200)
                .overlay {
                    if let error = c.loadError {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else if !c.ready {
                        ProgressView("Loading…")
                    }
                }

            HStack(spacing: 6) {
                Text(c.timecode(c.current))
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .frame(minWidth: 150, alignment: .leading)
                Spacer()
                transport("arrow.backward.to.line", "Go to start (↑)") { c.pause(); c.seek(c.inPoint) }
                transport("chevron.backward.2", "Back 1 second (Shift ←)") { c.step(-Int(c.fps.rounded())) }
                transport("chevron.backward", "Back 1 frame (←)") { c.step(-1) }
                transport(c.playing && !c.reversing ? "pause.fill" : "play.fill", "Play / pause (Space)") { c.togglePlay() }
                transport("chevron.forward", "Forward 1 frame (→)") { c.step(1) }
                transport("chevron.forward.2", "Forward 1 second (Shift →)") { c.step(Int(c.fps.rounded())) }
                transport("arrow.forward.to.line", "Go to end (↓)") { c.pause(); c.seek(c.outPoint) }
                Spacer()
                Text("Length \(lengthText)")
                    .font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    .help(c.intro == nil && c.outro == nil ? "How long the saved video will be"
                          : "How long the saved video will be, with the intro and outro")
                    .frame(minWidth: 150, alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Close-up").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $zoom) {
                        Text("10 sec").tag(10.0)
                        Text("30 sec").tag(30.0)
                        Text("2 min").tag(120.0)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                // Redrawn every screen refresh while playing, following the
                // player's clock (not whole-frame jumps), so it scrolls smoothly.
                TimelineView(.animation(paused: !c.playing)) { _ in
                    let now = c.playing ? c.smoothTime : nil
                    ScrubBar(c: c, range: detailRange(now), ticks: true, onDrag: { dragging in
                        frozen = dragging ? (c.current - zoom / 2)...(c.current + zoom / 2) : nil
                    }, onFrame: { zones.close = $0 }, now: now)
                }
                .frame(height: 90)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Whole video").font(.caption).foregroundStyle(.secondary)
                ScrubBar(c: c, range: 0...max(c.duration, 1), thumbnails: true, onFrame: { zones.whole = $0 })
                    .frame(height: 74)
            }

            HStack(alignment: .top, spacing: 24) {
                pointControl("Start", .green, c.inPoint, key: "I",
                             set: c.markIn, nudge: c.nudgeIn) { c.pause(); c.seek(c.inPoint) }
                pointControl("End", .red, c.outPoint, key: "O",
                             set: c.markOut, nudge: c.nudgeOut) { c.pause(); c.seek(c.outPoint) }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Button { c.playFromIn() } label: { Label("Play from start", systemImage: "play") }
                    Button { c.playToOut() } label: { Label("Play up to end", systemImage: "forward.end") }
                }
            }

            suggestionRow

            musicPanel

            clipPanel

            HStack(spacing: 18) {
                Toggle("Fade in and out (1 sec)", isOn: $c.fade)
                    .help("Fades the sermon in at the start and out at the end. Where there's an intro or outro, it cuts straight to it instead.")
                HStack(spacing: 6) {
                    Toggle("Even out the volume", isOn: $c.level)
                        .help("Brings the part you're keeping to a standard loudness, with a limiter for the loudest moments. Turn it on and off to compare.")
                    if c.levelBusy {
                        ProgressView().controlSize(.small)
                    } else if let g = c.levelGain {
                        Text(String(format: "%+.1f dB", g)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Toggle("Repair the voice (AI)", isOn: $c.repair)
                        .help("Rebuilds his voice with AI to undo the crunch when he's loud. Takes about 10 minutes per sermon. Turn it on and off to compare.")
                    if model.job == .repair { ProgressView().controlSize(.small) }
                }
                HStack(spacing: 6) {
                    Toggle("Auto color", isOn: $c.autoColor)
                        .help("Apple's auto-enhance, measured across the part you're keeping. Turn it on and off to compare.")
                    if c.colorBusy { ProgressView().controlSize(.small) }
                }
                Spacer()
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 18) {
                if c.musicNeedsSeparating && model.job != .music {
                    Text("Separate the music first (above), or set those sections to Original.")
                        .font(.callout).foregroundStyle(.orange)
                } else if c.repairNeeded && model.job != .repair {
                    Button("Repair the voice") { model.repairVoice() }
                        .disabled(model.job != nil)
                        .help("The start, end or music changed since the voice was repaired (or it hasn't been yet). About 10 minutes.")
                }
                Spacer()
                Toggle("Also make the English captions", isOn: $captionsWithTrim)
                    .help("Writes the captions while the video saves, so step 2 is already done.")
                Button("Save trimmed video") { model.makeTrim() }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(!c.ready || model.job != nil || c.musicNeedsSeparating || c.repairNeeded)
            }

            StatusArea(model: model)

            Text("Space play/pause  ·  ← → one frame  ·  Shift ← → one second  ·  J K L reverse/stop/forward  ·  I / O set start / end  ·  ↑ ↓ go to start / end  ·  1 2 3 switch the sound  ·  scroll over a timeline to move through it")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 900, minHeight: 800)
        .onAppear {
            installKeys()
            installScrolling()
        }
        .onChange(of: c.repair) { _, on in
            // Turning it on starts the repair, if there isn't one that fits.
            if on && c.repairNeeded && model.job == nil { model.repairVoice() }
        }
        .onChange(of: zoom) { _, z in zones.closeSpan = z }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            monitor = nil
            scrollMonitor = nil
            c.pause()
        }
    }

    private var suggestionRow: some View {
        HStack(alignment: .top, spacing: 24) {
            if let s = c.suggestions {
                suggestion("start", .green, s.starts, pick: $c.startPick,
                           time: c.startTime, hear: { c.hearStart($0, around: playAround) }, use: c.useStart)
                suggestion("end", .red, s.ends, pick: $c.endPick,
                           time: c.endTime, hear: { c.hearEnd($0, around: playAround) }, use: c.useEnd)
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Button("Suggest again") { model.suggestTrim() }
                        .disabled(!c.ready || model.job != nil)
                    Picker("▶ plays", selection: $playAround) {
                        Text("From the spot").tag(false)
                        Text("A few seconds around it").tag(true)
                    }
                    .pickerStyle(.menu).fixedSize()
                    .help("What the ▶ next to a suggestion plays")
                }
            } else {
                Button { model.suggestTrim() } label: { Label("Suggest start and end", systemImage: "sparkles") }
                    .disabled(!c.ready || model.job != nil)
                Text("Listens to the whole service for his welcome and sign-off, then picks the pause before or after. About 2 minutes per hour of video.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
    }

    private func suggestion(_ which: String, _ color: Color, _ list: [TrimSuggestion], pick: Binding<Int>,
                            time: @escaping (TrimSuggestion) -> Double,
                            hear: @escaping (TrimSuggestion) -> Void,
                            use: @escaping (TrimSuggestion) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let s = list[safe: pick.wrappedValue] {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(color)
                    Text("Suggested \(which)").font(.callout.weight(.semibold))
                    Button(c.timecode(time(s))) { c.pause(); c.seek(time(s)) }
                        .buttonStyle(.link).font(.system(.body, design: .monospaced))
                        .help("Go there")
                    Button { hear(s) } label: { Image(systemName: "play.fill") }
                        .help(playAround ? "Hear a few seconds either side" : "Play from here")
                    Button("Use") { use(s) }
                        .help("Set the \(which) here")
                    if list.count > 1 {
                        Menu("\(pick.wrappedValue + 1) of \(list.count)") {
                            ForEach(list.indices, id: \.self) { i in
                                Button("\(c.timecode(time(list[i])))  \(list[i].why)") { pick.wrappedValue = i }
                            }
                        }
                        .fixedSize()
                        .help("Other places it could \(which)")
                    }
                }
                Text(s.why).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).frame(maxWidth: 440, alignment: .leading)
            } else {
                Label("No \(which) found", systemImage: "sparkles").foregroundStyle(.secondary)
            }
        }
        .disabled(!c.ready)
    }

    private var musicPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(Color.purple).frame(width: 10, height: 10)
                Text("Music behind the speaking").font(.headline)
                Text(c.sections.isEmpty
                     ? "Put the playhead where the music starts and click Add section."
                     : "Play a section and switch between the three while it plays (keys 1 2 3).")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button {
                    if let why = c.addSection() { model.show(why, error: true) }
                } label: { Label("Add section at playhead", systemImage: "plus") }
                    .disabled(!c.ready || model.job == .music)
            }
            ForEach(Array(c.sections.enumerated()), id: \.element.id) { i, m in
                sectionRow(i + 1, m)
            }
            if !c.unseparated.isEmpty {
                HStack(spacing: 10) {
                    if model.job == .music {
                        Text("Separating the music… the Original plays until it's done.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Button(c.unseparated.count == c.sections.count && c.sections.count == 1
                               ? "Separate the music" : "Separate the music (\(c.unseparated.count) to do)") {
                            model.separateMusic()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.job != nil)
                        Text(c.musicNeedsSeparating ? "Needed before you can hear or save the choices."
                             : "Then switch between the three to compare.")
                            .font(.callout).foregroundStyle(c.musicNeedsSeparating ? Color.orange : Color.secondary)
                    }
                }
            }
            if let note = c.musicPreviewNote {
                Label(note, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.08)))
    }

    private func sectionRow(_ number: Int, _ m: MusicSection) -> some View {
        let busy = model.job == .music
        return HStack(spacing: 8) {
            Text("\(number)").font(.callout.monospacedDigit().weight(.semibold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.purple.opacity(c.activeSection == m.id ? 0.6 : 0.25)))
            Button(c.timecode(m.from)) { c.pause(); c.seek(m.from) }
                .buttonStyle(.link).font(.system(.body, design: .monospaced))
                .help("Go to where this section starts")
            Text("to").foregroundStyle(.secondary)
            Button(c.timecode(m.to)) { c.pause(); c.seek(m.to) }
                .buttonStyle(.link).font(.system(.body, design: .monospaced))
                .help("Go to where this section ends")
            Button("Section starts here") { c.setSectionStart(m.id) }.disabled(busy)
                .help("Move this music section's start to the playhead")
            Button("Section ends here") { c.setSectionEnd(m.id) }.disabled(busy)
                .help("Move this music section's end to the playhead")
            Picker("", selection: Binding(get: { m.choice }, set: { c.setChoice(m.id, $0) })) {
                ForEach(MusicChoice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Button { c.playSection(m.id) } label: { Image(systemName: "play.fill") }
                .help("Play this section")
            Group {
                if c.musicFiles[m.id] != nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        .help("Separated: all three choices can be heard")
                } else {
                    Image(systemName: "circle.dashed").foregroundStyle(m.choice == .original ? Color.secondary : Color.orange)
                        .help("Not separated yet")
                }
                if c.outsideTrim(m) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .help("This section is outside the part you're keeping, so it won't change the saved video.")
                }
            }
            Spacer()
            Button { c.removeSection(m.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).disabled(busy).help("Remove this section")
        }
        .disabled(!c.ready)
    }

    private var clipPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 28) {
                clipSlot(.intro)
                clipSlot(.outro)
                Spacer()
            }
            if let note = c.clipNote {
                Label(note, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            }
        }
        .disabled(!c.ready)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    private func clipSlot(_ slot: ClipSlot) -> some View {
        let clip = slot == .intro ? c.intro : c.outro
        let title = slot == .intro ? "Intro" : "Outro"
        return HStack(spacing: 8) {
            Image(systemName: clip == nil ? "film" : "film.fill")
                .foregroundStyle(clip == nil ? Color.secondary : Color.accentColor)
            Text(title).font(.headline)
            if let clip {
                Text(clip.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 240, alignment: .leading)
                    .help(clip.url.path)
                Text(clockText(clip.duration)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Button {
                    c.pause()
                    watching = slot
                } label: { Image(systemName: "play.fill") }
                    .help("Watch the \(slot.name)")
                    .popover(isPresented: Binding(get: { watching == slot }, set: { if !$0 && watching == slot { watching = nil } })) {
                        ClipPlayer(url: clip.url)
                    }
                Button("Change…") { pickClip(slot) }
                Button { useClip(slot, nil) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Take the \(slot.name) off")
            } else {
                Button("Add \(slot.name)…") { pickClip(slot) }
                    .help(slot == .intro ? "A video to put before the sermon, as it is (or drop one here)"
                                         : "A video to put after the sermon, as it is (or drop one here)")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .movie) == true })
            else { return false }
            useClip(slot, u)
            return true
        }
    }

    private func pickClip(_ slot: ClipSlot) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.message = slot == .intro ? "Choose the video to put before the sermon"
                                       : "Choose the video to put after the sermon"
        if panel.runModal() == .OK, let u = panel.url { useClip(slot, u) }
    }

    private func useClip(_ slot: ClipSlot, _ url: URL?) {
        Task {
            if let why = await c.chooseClip(slot, url) { model.show(why, error: true) }
        }
    }

    private func clockText(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var lengthText: String {
        let s = Int(c.savedSeconds.rounded())
        return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    private func transport(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 18) }
            .help(help)
            .disabled(!c.ready)
    }

    private func pointControl(_ title: String, _ color: Color, _ t: Double, key: String,
                              set: @escaping () -> Void, nudge: @escaping (Int) -> Void,
                              go: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(title).font(.headline)
                Button(c.timecode(t), action: go)
                    .buttonStyle(.link)
                    .font(.system(.body, design: .monospaced))
                    .help("Go to the \(title.lowercased()) frame")
            }
            HStack(spacing: 6) {
                Button("Set to playhead (\(key))", action: set)
                Button { nudge(-1) } label: { Image(systemName: "minus") }.help("1 frame earlier")
                Button { nudge(1) } label: { Image(systemName: "plus") }.help("1 frame later")
            }
            .disabled(!c.ready)
        }
    }

    /// Two-finger swipe (or a scroll wheel) over a timeline moves through the
    /// video at that timeline's scale: finely on the close-up, quickly on the
    /// whole video. The picture follows the fingers, like scrolling a page.
    private func installScrolling() {
        guard scrollMonitor == nil else { return }
        let c = c, zones = zones
        zones.closeSpan = zoom
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            guard e.window?.title == TrimEditor.title, let view = e.window?.contentView else { return e }
            let p = view.convert(e.locationInWindow, from: nil)
            let point = CGPoint(x: p.x, y: view.isFlipped ? p.y : view.bounds.height - p.y)
            var delta = abs(e.scrollingDeltaX) >= abs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY
            if !e.hasPreciseScrollingDeltas { delta *= 12 }   // a mouse wheel counts in lines
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard c.ready, delta != 0 else { return false }
                let perPoint: Double
                if zones.close.contains(point) {
                    perPoint = zones.closeSpan / max(Double(zones.close.width), 1)
                } else if zones.whole.contains(point) {
                    perPoint = c.duration / max(Double(zones.whole.width), 1)
                } else {
                    return false
                }
                if c.playing { c.pause() }
                // Keep the fraction of a frame between events, so slow
                // scrolling on the close-up still creeps along.
                let base = zones.position.map { abs($0 - c.current) < 2 * c.frameDuration ? $0 : c.current } ?? c.current
                let t = min(max(base - Double(delta) * perPoint, 0), c.duration)
                zones.position = t
                c.seek(t)
                return true
            }
            return handled ? nil : e
        }
    }

    private func installKeys() {
        guard monitor == nil else { return }
        let c = c
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.window?.title == TrimEditor.title,
                  e.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return e }
            let shift = e.modifierFlags.contains(.shift)
            let keyCode = e.keyCode
            let chars = e.charactersIgnoringModifiers?.lowercased()
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard c.ready else { return false }
                let second = Int(c.fps.rounded())
                switch keyCode {
                case 49: c.togglePlay()                       // space
                case 123: c.step(shift ? -second : -1)        // ←
                case 124: c.step(shift ? second : 1)          // →
                case 126: c.pause(); c.seek(c.inPoint)        // ↑
                case 125: c.pause(); c.seek(c.outPoint)       // ↓
                default:
                    switch chars {
                    case "i": c.markIn()
                    case "o": c.markOut()
                    case "j": c.shuttle(-1)
                    case "k": c.pause()
                    case "l": c.shuttle(1)
                    case "1", "2", "3":
                        return c.setChoiceHere([.original, .down, .removed][Int(chars ?? "1")! - 1])
                    default: return false
                    }
                }
                return true
            }
            return handled ? nil : e
        }
    }
}

/// Plays an intro or outro in a popover.
struct ClipPlayer: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .frame(width: 480, height: 270)
            .onAppear {
                let p = AVPlayer(url: url)
                player = p
                p.play()
            }
            .onDisappear { player?.pause() }
    }
}

struct TrimWindow: View {
    @ObservedObject var model: Model

    var body: some View {
        if let c = model.trim {
            TrimEditor(model: model, c: c)
        } else {
            Text("Drop the video from Subsplash into step 1 first.")
                .foregroundStyle(.secondary)
                .frame(minWidth: 500, minHeight: 300)
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Where the two timelines are in the trim window (SwiftUI's window
/// coordinates), for the scroll handler, plus where scrolling has got to.
final class TimelineZones {
    var close: CGRect = .zero
    var whole: CGRect = .zero
    var closeSpan = 30.0
    var position: Double?
}

/// A finished voice repair: the file and the span of the video it covers.
struct RepairTake: Equatable {
    let url: URL
    let from: Double
    let to: Double
}
