// Sermon Captions: drop the English sermon video to get English captions
// (SRT) for HeyGen, then drop HeyGen's Spanish video to get it back with
// those English captions retimed and burned in. The work is done by
// sermon_captions.py (bundled in Resources); this is the window around it.

import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// From the VERSION file, which build.sh writes into Info.plist.
let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

/// Everything the app runs ships inside it (Resources/python, Resources/bin,
/// Resources/models), except the Whisper model, which sermon_captions.py
/// downloads on first use.
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
    static let python = resources.appendingPathComponent("python/bin/python3")
    static let script = resources.appendingPathComponent("sermon_captions.py")
    static let model = home.appendingPathComponent(
        "Library/Application Support/Sermon Captions/ggml-large-v3-turbo.bin")
    static let output = home.appendingPathComponent("Movies/Sermon Captions")
    static let musicCache = home.appendingPathComponent("Library/Caches/Sermon Captions/Music")
    static let colorCache = home.appendingPathComponent("Library/Caches/Sermon Captions/Color")
    static let repairCache = home.appendingPathComponent("Library/Caches/Sermon Captions/Repair")
    static let caches = home.appendingPathComponent("Library/Caches/Sermon Captions")
    /// Set up per Mac (see sermon_captions.py `send`); without it there's no copying to ProPresenter.
    static let proPresenter = home.appendingPathComponent("Library/Application Support/Sermon Captions/ProPresenter")
    static var canCopyToProPresenter: Bool {
        FileManager.default.fileExists(atPath: proPresenter.appendingPathComponent("config.json").path)
    }
    /// Set up to copy to a different Mac (not this one being the ProPresenter Mac).
    static var copiesToOtherMac: Bool {
        guard let data = try? Data(contentsOf: proPresenter.appendingPathComponent("config.json")),
              let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return cfg["host"] != nil
    }

    /// Music, voice repairs and color looks nobody has made or used in a month.
    /// They're only there to make a second save of the same sermon quick.
    /// A WAV and its ".ref" go together, by whichever was used last.
    static func cleanCaches() {
        let fm = FileManager.default
        let old = Date().addingTimeInterval(-30 * 86400)
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .contentAccessDateKey]
        guard let files = fm.enumerator(at: caches, includingPropertiesForKeys: keys) else { return }
        var groups: [String: (used: Date, files: [URL])] = [:]
        for case let f as URL in files {
            guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let used = max(v.contentModificationDate ?? .distantPast, v.contentAccessDate ?? .distantPast)
            let key = f.pathExtension == "ref" ? f.deletingPathExtension().path : f.path
            let g = groups[key] ?? (.distantPast, [])
            groups[key] = (max(g.used, used), g.files + [f])
        }
        for g in groups.values where g.used < old {
            g.files.forEach { try? fm.removeItem(at: $0) }
        }
    }

    static func missing() -> [String] {
        let needed = [python, script, resources.appendingPathComponent("models/htdemucs.safetensors")]
            + ["ffmpeg", "ffprobe", "whisper-cli"].map { resources.appendingPathComponent("bin/\($0)") }
        return needed.filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.lastPathComponent)
    }
}

/// Splits a pipe's output into lines as it arrives.
final class LineReader {
    private var buffer = Data()
    private let onLine: (String) -> Void

    init(_ handle: FileHandle, onLine: @escaping (String) -> Void) {
        self.onLine = onLine
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self else { return }
            if data.isEmpty {
                h.readabilityHandler = nil
                self.flush()
                return
            }
            self.buffer.append(data)
            while let nl = self.buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: self.buffer[..<nl], as: UTF8.self)
                self.buffer.removeSubrange(...nl)
                self.onLine(line)
            }
        }
    }

    private func flush() {
        if !buffer.isEmpty {
            onLine(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
        }
    }
}

@MainActor
final class Model: ObservableObject {
    enum Job { case trim, music, repair, suggest, english, spanish, copy, copyEnglish }

    /// The untrimmed video, straight from Subsplash.
    @Published var sourceVideo: URL? { didSet { sourceChanged(from: oldValue) } }
    @Published private(set) var trimmedVideo: URL?
    @Published private(set) var trim: TrimController?
    @Published var englishVideo: URL? { didSet { refresh() } }
    @Published var spanishVideo: URL? { didSet { refresh() } }
    @Published private(set) var englishSRT: URL?
    @Published private(set) var spanishSRT: URL?
    @Published private(set) var spanishOut: URL?
    @Published private(set) var job: Job?
    @Published private(set) var stage = ""
    @Published private(set) var progress = 0.0
    @Published private(set) var started = Date()
    @Published var message: String?
    @Published var messageIsError = false
    let missing = Paths.missing()

    private var process: Process?
    private var readers: [LineReader] = []

    init() {
        // Don't leave a job (and the GPU) running after the app quits.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.process?.terminate() }
        }
        DispatchQueue.global(qos: .utility).async { Paths.cleanCaches() }
    }
    private var stderrTail: [String] = []
    private var lastError: String?
    private var lastWarning: String?
    private var cancelled = false
    /// The trim also made captions this time.
    private var trimMadeCaptions = false
    /// Where the running repair writes.
    private var repairOut: URL?
    /// Where the copy job put the video on the ProPresenter Mac.
    private var lastNote: String?
    /// What was just made, when copying it to ProPresenter follows.
    private var readyNote: String?

    /// How the captions look on the Spanish video (step 3), and the style each
    /// finished one was made with, by its path (none recorded: Box, the only
    /// style before there was a choice).
    static let captionStyleKey = "captionStyle"
    static var captionStyle: CaptionStyle {
        CaptionStyle(rawValue: UserDefaults.standard.string(forKey: captionStyleKey) ?? "") ?? .box
    }
    static let madeStylesKey = "spanishCaptionStyles"
    static func madeStyle(_ video: URL) -> CaptionStyle {
        let made = UserDefaults.standard.dictionary(forKey: madeStylesKey) as? [String: String] ?? [:]
        return made[video.standardizedFileURL.path].flatMap(CaptionStyle.init(rawValue:)) ?? .box
    }
    /// The style the Spanish video being made now has, and when it started.
    private var makingStyle: CaptionStyle?
    private var makingSince: Date?

    /// "Copy it to the ProPresenter Mac" in step 3 (on unless turned off).
    static let copyToProPresenterKey = "copyToProPresenter"
    static var copyToProPresenter: Bool {
        UserDefaults.standard.object(forKey: copyToProPresenterKey) as? Bool ?? true
    }

    /// "Copy the trimmed video and captions to the ProPresenter Mac" in step 2 (off unless turned on).
    static let copyEnglishToProPresenterKey = "copyEnglishToProPresenter"
    static var copyEnglishToProPresenter: Bool {
        UserDefaults.standard.bool(forKey: copyEnglishToProPresenterKey)
    }

    /// "Also make the English captions" in the trim window (on unless turned off).
    static let captionsWithTrimKey = "captionsWithTrim"
    static var captionsWithTrim: Bool {
        UserDefaults.standard.object(forKey: captionsWithTrimKey) as? Bool ?? true
    }

    /// Everything for one sermon lives in ~/Movies/Sermon Captions/<video name>/.
    /// A video that's already in one of those folders (like the trimmed copy)
    /// belongs to that folder.
    private func sermonFolder(_ video: URL) -> URL {
        let parent = video.deletingLastPathComponent().standardizedFileURL
        if parent.deletingLastPathComponent().path == Paths.output.standardizedFileURL.path {
            return parent
        }
        return Paths.output.appendingPathComponent(baseName(video))
    }

    var folder: URL? { (englishVideo ?? sourceVideo).map(sermonFolder) }
    private var trimmedPath: URL? {
        sourceVideo.map { sermonFolder($0).appendingPathComponent("\(baseName($0)) - Trimmed.mp4") }
    }
    private var suggestionsPath: URL? {
        sourceVideo.map { sermonFolder($0).appendingPathComponent("\(baseName($0)) start and end suggestions.json") }
    }
    private var trimPointsPath: URL? {
        sourceVideo.map { sermonFolder($0).appendingPathComponent("\(baseName($0)) trim points.json") }
    }
    private var englishSRTPath: URL? {
        englishVideo.flatMap { v in folder?.appendingPathComponent("\(baseName(v)) - English captions (English timing).srt") }
    }
    private var spanishSRTPath: URL? {
        spanishVideo.flatMap { v in folder?.appendingPathComponent("\(baseName(v)) - English captions (Spanish timing).srt") }
    }
    private var spanishOutPath: URL? {
        spanishVideo.flatMap { v in folder?.appendingPathComponent("\(baseName(v)) - English captions.mp4") }
    }

    private func baseName(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    private func existing(_ url: URL?) -> URL? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func refresh() {
        trimmedVideo = existing(trimmedPath)
        englishSRT = existing(englishSRTPath)
        spanishSRT = existing(spanishSRTPath)
        spanishOut = existing(spanishOutPath)
    }

    private func modified(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// The video was re-trimmed (or re-exported) after its captions were made.
    var englishIsStale: Bool {
        guard let v = englishVideo, let srt = englishSRT else { return false }
        return modified(v) > modified(srt)
    }

    /// The English captions were edited after the Spanish video was made.
    var spanishIsStale: Bool {
        guard let en = englishSRT, let es = spanishSRT else { return false }
        return modified(en) > modified(es)
    }

    var canMakeEnglish: Bool { job == nil && missing.isEmpty && englishVideo != nil }
    var canMakeSpanish: Bool {
        job == nil && missing.isEmpty && englishVideo != nil && spanishVideo != nil && englishSRT != nil
    }

    private func sourceChanged(from old: URL?) {
        guard old?.standardizedFileURL != sourceVideo?.standardizedFileURL else { return }
        trim?.shutdown()
        trim = nil
        // Step 2 follows the new sermon unless it holds a video the user chose themselves.
        let oldTrimmed = old.map { sermonFolder($0).appendingPathComponent("\(baseName($0)) - Trimmed.mp4") }
        refresh()
        guard sourceVideo != nil else { return }   // clearing step 1 leaves steps 2 and 3 alone
        if englishVideo == nil || englishVideo?.standardizedFileURL == oldTrimmed?.standardizedFileURL {
            if englishVideo != trimmedVideo { spanishVideo = nil }
            englishVideo = trimmedVideo
        }
    }

    /// Set up the trim window for the current source video.
    func prepareTrim() {
        guard let src = sourceVideo else { return }
        if trim?.url == src { return }
        trim?.shutdown()
        var saved: TrimPoints?
        if let p = trimPointsPath, let data = try? Data(contentsOf: p) {
            saved = try? JSONDecoder().decode(TrimPoints.self, from: data)
        }
        let c = TrimController(url: src, saved: saved)
        c.onChange = { [weak self, weak c] in
            guard let self, let c, c.ready, self.trim === c, let p = self.trimPointsPath else { return }
            try? FileManager.default.createDirectory(at: p.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(c.points).write(to: p)
        }
        c.loadSuggestions(savedSuggestions())
        trim = c
    }

    func makeTrim() {
        guard let src = sourceVideo, let out = trimmedPath, let c = trim, c.ready, job == nil else { return }
        c.refreshMusic()
        if c.musicNeedsSeparating {
            show("Separate the music first, or set those sections to Original.", error: true)
            return
        }
        if c.repairNeeded {
            show("The voice needs repairing again first (the start, end or music changed). Click Repair the voice, or turn it off.", error: true)
            return
        }
        c.pause()
        c.onChange?()
        Task {
            if c.autoColor, !(await c.ensureColor()) {
                show("Couldn't measure the color for Auto color. Turn it off to save without it.", error: true)
                return
            }
            if c.level, !(await c.ensureLevel()) {
                show("Couldn't measure the volume for Even out the volume. Turn it off to save without it.", error: true)
                return
            }
            guard job == nil else { return }
            // Named as step 2 will look for them once the trimmed video is there.
            let srt = out.deletingLastPathComponent()
                .appendingPathComponent("\(baseName(out)) - English captions (English timing).srt")
            trimMadeCaptions = Self.captionsWithTrim
            run(.trim, ["trim"] + (trimMadeCaptions ? ["--captions", srt.path] : []) + c.repairArgs + c.clipArgs
                    + [src.path, out.path, String(format: "%.6f", c.exportStart),
                       String(format: "%.6f", c.exportLength), c.fade ? "1" : "0", c.levelArg,
                       c.colorArg] + c.musicArgs,
                in: out.deletingLastPathComponent())
        }
    }

    private func savedSuggestions() -> TrimSuggestions? {
        guard let p = suggestionsPath, let data = try? Data(contentsOf: p) else { return nil }
        return try? JSONDecoder().decode(TrimSuggestions.self, from: data)
    }

    /// Listen to the whole untrimmed service for where to start and end.
    func suggestTrim() {
        guard let src = sourceVideo, let out = suggestionsPath, trim?.ready == true else { return }
        run(.suggest, ["suggest", src.path, out.path], in: out.deletingLastPathComponent())
    }

    /// Rebuild his voice for the part being kept (plus 30 s each side), with
    /// the music choices as they are now. One repair per video is kept.
    func repairVoice() {
        guard let c = trim, c.ready, job == nil, !c.musicNeedsSeparating else { return }
        let span = c.repairSpan
        let out = c.repairPath(from: span.from, to: span.to)
        repairOut = out
        run(.repair, ["repair", c.url.path, String(format: "%.3f", span.from), String(format: "%.3f", span.to - span.from),
                      out.path] + c.repairJobMusicArgs, in: Paths.repairCache)
    }

    /// After a repair: keep only the new one for this video, and nothing over a month old.
    private func cleanRepairCache(keeping out: URL, key: String) {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: Paths.repairCache, includingPropertiesForKeys: nil)) ?? []
        where f.lastPathComponent != out.lastPathComponent && f.lastPathComponent != out.lastPathComponent + ".ref"
            && (f.lastPathComponent.hasPrefix(key + " ") || modified(f) < Date().addingTimeInterval(-30 * 86400)) {
            try? fm.removeItem(at: f)
        }
    }

    /// Split the voice from the music in every trim editor section not done yet.
    func separateMusic() {
        guard let c = trim, c.ready else { return }
        c.refreshMusic()   // a stopped job may have finished some sections
        guard !c.unseparated.isEmpty else { return }
        cleanMusicCache(c)
        run(.music, ["separate", c.url.path] + c.separateArgs, in: Paths.musicCache)
    }

    /// Keep only this video's current sections, and nothing older than a month.
    private func cleanMusicCache(_ c: TrimController) {
        let fm = FileManager.default
        let old = Date().addingTimeInterval(-30 * 86400)
        let keep = Set(c.sections.flatMap { m in [c.musicPath(m).lastPathComponent, c.musicPath(m).lastPathComponent + ".ref"] })
        for f in (try? fm.contentsOfDirectory(at: Paths.musicCache, includingPropertiesForKeys: nil)) ?? []
        where !keep.contains(f.lastPathComponent)
            && (f.lastPathComponent.hasPrefix(c.sourceKey + " ") || modified(f) < old) {
            try? fm.removeItem(at: f)
        }
    }

    func makeEnglish() {
        guard let v = englishVideo, let out = englishSRTPath else { return }
        run(.english, ["transcribe", v.path, out.path], in: out.deletingLastPathComponent())
    }

    func makeSpanish() {
        guard let o = englishVideo, let s = spanishVideo, let en = englishSRT,
              let srt = spanishSRTPath, let mp4 = spanishOutPath else { return }
        let style = Self.captionStyle
        makingStyle = style
        makingSince = Date()
        run(.spanish, ["spanish", "--style", style.rawValue, o.path, s.path, en.path, srt.path, mp4.path],
            in: mp4.deletingLastPathComponent())
    }

    func copyToProPresenter() {
        guard let mp4 = spanishOut, job == nil, Paths.canCopyToProPresenter else { return }
        run(.copy, ["send", mp4.path], in: mp4.deletingLastPathComponent())
    }

    /// The video in step 2 and its captions, into the same sermon folder on
    /// the ProPresenter Mac, to finish step 3 there.
    func copyEnglishToProPresenter() {
        guard let v = englishVideo, let srt = englishSRT, let f = folder, job == nil, Paths.copiesToOtherMac else { return }
        run(.copyEnglish, ["send", "--to", f.lastPathComponent, v.path, srt.path], in: f)
    }

    /// Replace the English captions with an SRT the user edited elsewhere.
    func importEnglishSRT(_ url: URL) {
        guard let dest = englishSRTPath, url.standardizedFileURL != dest.standardizedFileURL else { return }
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
            show("Using \(url.lastPathComponent) as the English captions.")
        } catch {
            show("Couldn't copy that SRT: \(error.localizedDescription)", error: true)
        }
        refresh()
    }

    func cancel() {
        cancelled = true
        process?.terminate()
    }

    func show(_ text: String, error: Bool = false) {
        message = text
        messageIsError = error
    }

    private func run(_ which: Job, _ args: [String], in folder: URL) {
        let script = Paths.script
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            show("Couldn't create \(folder.path): \(error.localizedDescription)", error: true)
            return
        }
        let p = Process()
        p.executableURL = Paths.python
        p.arguments = ["-u", script.path] + args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin"
        env.removeValue(forKey: "PYTHONHOME")
        env.removeValue(forKey: "PYTHONPATH")
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        stderrTail = []
        lastError = nil
        lastWarning = nil
        lastNote = nil
        cancelled = false
        readers = [
            LineReader(out.fileHandleForReading) { line in
                Task { @MainActor in self.handle(line) }
            },
            LineReader(err.fileHandleForReading) { line in
                Task { @MainActor in self.stderrTail = Array((self.stderrTail + [line]).suffix(15)) }
            },
        ]
        p.terminationHandler = { proc in
            let status = proc.terminationStatus
            // Let the readers deliver the last lines before reporting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                Task { @MainActor in self.finished(which, status: status) }
            }
        }
        job = which
        stage = "Starting…"
        progress = 0
        started = Date()
        message = nil
        do {
            try p.run()
            process = p
        } catch {
            job = nil
            show("Couldn't start: \(error.localizedDescription)", error: true)
        }
    }

    private func handle(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let kind = parts.first else { return }
        let rest = parts.count > 1 ? parts[1] : ""
        switch kind {
        case "STAGE": stage = rest
        case "PROGRESS": progress = Double(rest) ?? progress
        case "ERROR": lastError = rest
        case "WARN": lastWarning = rest
        case "NOTE": lastNote = rest
        default: break
        }
    }

    private func finished(_ which: Job, status: Int32) {
        process = nil
        readers = []
        job = nil
        refresh()
        // Sections a stopped or failed separation did finish still count.
        if which == .music || which == .repair { trim?.refreshMusic() }
        let ok = !cancelled && status == 0
        // The style the Spanish video now has, going by the file itself (Stop
        // right at the end can come after it's been written).
        if which == .spanish, let mp4 = spanishOut, let style = makingStyle, let since = makingSince,
           modified(mp4) >= since {
            var made = UserDefaults.standard.dictionary(forKey: Self.madeStylesKey) as? [String: String] ?? [:]
            made[mp4.standardizedFileURL.path] = style.rawValue
            UserDefaults.standard.set(made, forKey: Self.madeStylesKey)
        }
        var copyNext = false, copyEnglishNext = false
        if which != .copy && which != .copyEnglish { readyNote = nil }
        if cancelled {
            readyNote = nil
            show("Stopped.")
        } else if status == 0 {
            let took = Int(Date().timeIntervalSince(started))
            let time = took >= 60 ? "\(took / 60) min \(took % 60) sec" : "\(took) sec"
            let place = lastNote.map { ", in \($0.replacingOccurrences(of: "/", with: " › "))" } ?? ""
            switch which {
            case .suggest:
                trim?.loadSuggestions(savedSuggestions())
                show("Suggestions are ready (\(time)). Check each one with ▶ before you click Use.")
            case .repair:
                if let out = repairOut, let key = trim?.sourceKey { cleanRepairCache(keeping: out, key: key) }
                show("His voice is repaired (\(time)). Turn Repair the voice off and on while it plays to compare.")
            case .music:
                show("The music is separated. Play a section and switch between the three (keys 1, 2, 3) to compare. Saving uses what's picked for each section.")
            case .trim:
                if let t = trimmedVideo {
                    if englishVideo != t { spanishVideo = nil }   // a Spanish video for some other cut
                    englishVideo = t
                }
                if let warning = lastWarning {
                    show(warning, error: true)
                } else if trimMadeCaptions {
                    show("The trimmed video and its English captions are ready (\(time)), in step 2. Check the captions over, then upload the SRT to HeyGen. (If you finish the video in iMovie, drop that export into step 2 and make the captions again.)")
                } else {
                    show("The trimmed video is ready (\(time)) and loaded into step 2. If you finish it in iMovie, drop that export into step 2 instead.")
                }
            case .english:
                show("English captions are ready (\(time)). Check them over, then upload the SRT to HeyGen.")
            case .spanish:
                show("The Spanish video with English captions is ready (\(time)).")
            case .copy:
                show([readyNote, "Copied to the ProPresenter Mac\(place)."].compactMap { $0 }.joined(separator: " "))
                readyNote = nil
            case .copyEnglish:
                show([readyNote, "Copied the video and its captions to the ProPresenter Mac\(place). To finish there, drop that video into step 2."]
                    .compactMap { $0 }.joined(separator: " "))
                readyNote = nil
            }
            // (Decided after the switch: a trim only loads its video into step 2 above.)
            copyNext = which == .spanish && Paths.canCopyToProPresenter && Self.copyToProPresenter
            copyEnglishNext = (which == .english || which == .trim) && Paths.copiesToOtherMac
                && Self.copyEnglishToProPresenter && englishVideo != nil && englishSRT != nil && !englishIsStale
            if copyNext || copyEnglishNext {
                readyNote = message
                DispatchQueue.main.async { [weak self] in
                    if copyNext { self?.copyToProPresenter() } else { self?.copyEnglishToProPresenter() }
                }
            }
        } else {
            let why = lastError ?? stderrTail.joined(separator: "\n").ifEmpty("Something went wrong (exit \(status)).")
            // What was made is fine when only the copy failed.
            show(readyNote.map { "\($0) It didn't get to the ProPresenter Mac, though. \(why)" } ?? why, error: true)
            readyNote = nil
        }
        // Repair the voice was turned on (or the music changed) while
        // something else was running: start it now (after the copy to ProPresenter, if one is next).
        if ok, which != .repair, !copyNext, !copyEnglishNext, let c = trim, c.repair, c.repairNeeded, !c.musicNeedsSeparating {
            DispatchQueue.main.async { [weak self] in self?.repairVoice() }
        }
    }
}

extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}

// MARK: - Views

struct ContentView: View {
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Model.copyToProPresenterKey) private var copyToProPresenter = true
    @AppStorage(Model.captionStyleKey) private var captionStyle = CaptionStyle.box
    @AppStorage(Model.copyEnglishToProPresenterKey) private var copyEnglishToProPresenter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !model.missing.isEmpty {
                Label("This copy of the app is incomplete (missing \(model.missing.joined(separator: ", "))). Reinstall it.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            StepCard(number: 1, title: "Trim",
                     detail: "Drop the video from Subsplash, then pick exactly where it starts and ends.") {
                DropZone(title: "Video from Subsplash", url: $model.sourceVideo, types: [.movie],
                         disabled: model.job != nil)
                HStack(alignment: .center, spacing: 12) {
                    Button("Open trim editor") {
                        model.prepareTrim()
                        openWindow(id: "trim")
                    }
                    .fixedSize()
                    .disabled(model.sourceVideo == nil)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    Spacer()
                    if let t = model.trimmedVideo { FileTile(url: t, label: "Trimmed video") }
                }
            }

            StepCard(number: 2, title: "English captions",
                     detail: "The trimmed video lands here automatically. If you finish it in iMovie, drop that export here instead. You'll get an SRT to check over and upload to HeyGen.") {
                DropZone(title: "English video", url: $model.englishVideo, types: [.movie],
                         disabled: model.job != nil)
                HStack(alignment: .center, spacing: 12) {
                    Button(model.englishSRT == nil ? "Make English captions" : "Make them again") {
                        model.makeEnglish()
                    }
                    .disabled(!model.canMakeEnglish)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .opacity(model.englishSRT == nil ? 1 : 0.9)
                    if model.englishSRT == nil && model.job == nil
                        && !FileManager.default.fileExists(atPath: Paths.model.path) {
                        Text("The first run also downloads a 1.6 GB speech model.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let srt = model.englishSRT {
                        FileTile(url: srt, label: "Captions – English timing", extra: ("Edit", { NSWorkspace.shared.open(
                            [srt], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                            configuration: NSWorkspace.OpenConfiguration()) }))
                        .dropDestination(for: URL.self) { urls, _ in
                            guard let u = urls.first, u.pathExtension.lowercased() == "srt" else { return false }
                            model.importEnglishSRT(u)
                            return true
                        }
                        .help("Drag this into HeyGen. Drop an edited .srt here to replace it.")
                    }
                }
                if Paths.copiesToOtherMac {
                    HStack(spacing: 12) {
                        Toggle("Copy the video and captions to the ProPresenter Mac when they're done", isOn: $copyEnglishToProPresenter)
                            .font(.callout)
                            .help("To finish step 3 on the ProPresenter Mac. They go into the same sermon folder there.")
                        Spacer()
                        if model.englishVideo != nil && model.englishSRT != nil {
                            Button("Copy to ProPresenter") { model.copyEnglishToProPresenter() }
                                .fixedSize()
                                .disabled(model.job != nil || model.englishIsStale)
                                .help("Copies this video and its captions into Movies › Sermon Captions on the ProPresenter Mac.")
                        }
                    }
                }
                if model.englishIsStale && model.job == nil {
                    Label("The video changed after these captions were made. Click Make them again.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
            }

            StepCard(number: 3, title: "Spanish video",
                     detail: "After HeyGen, drop the Spanish video here. The same English captions get retimed to match it and burned in.") {
                DropZone(title: "Spanish video from HeyGen", url: $model.spanishVideo, types: [.movie],
                         disabled: model.job != nil)
                HStack(spacing: 12) {
                    Text("Caption style").font(.callout).foregroundStyle(.secondary)
                    ForEach(CaptionStyle.allCases) { style in
                        CaptionStyleTile(style: style, selected: captionStyle == style) { captionStyle = style }
                    }
                    Spacer()
                }
                .disabled(model.job == .spanish)
                HStack(alignment: .center, spacing: 12) {
                    Button("Add English captions") { model.makeSpanish() }
                        .fixedSize()
                        .disabled(!model.canMakeSpanish)
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                    if model.spanishVideo != nil && model.englishSRT == nil {
                        Text(model.englishVideo == nil ? "Drop the English video in step 2 too." : "Make the English captions first.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if Paths.canCopyToProPresenter {
                    HStack(spacing: 12) {
                        Toggle("Copy it to the ProPresenter Mac when it's done", isOn: $copyToProPresenter)
                            .font(.callout)
                        Spacer()
                        if model.spanishOut != nil {
                            Button("Copy to ProPresenter") { model.copyToProPresenter() }
                                .fixedSize()
                                .disabled(model.job != nil)
                                .help("Copies this video to the ProPresenter Mac's Movies › Spanish sermons folder.")
                        }
                    }
                }
                if model.spanishSRT != nil || model.spanishOut != nil {
                    HStack(spacing: 12) {
                        Spacer()
                        if let srt = model.spanishSRT { FileTile(url: srt, label: "Captions – Spanish timing") }
                        if let mp4 = model.spanishOut { FileTile(url: mp4, label: "Spanish video with captions") }
                    }
                }
                if let mp4 = model.spanishOut, model.job == nil, !model.spanishIsStale,
                   Model.madeStyle(mp4) != captionStyle {
                    Label("This Spanish video has the \(Model.madeStyle(mp4).title) captions. Click Add English captions to make it with \(captionStyle.title) instead.",
                          systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if model.spanishIsStale && model.job == nil {
                    Label("The English captions changed after this was made. Click Add English captions again to update it.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
            }

            StatusArea(model: model)

            HStack(spacing: 10) {
                Text("Version \(appVersion)")
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                if let folder = model.folder, FileManager.default.fileExists(atPath: folder.path) {
                    Button {
                        NSWorkspace.shared.open(folder)
                    } label: { Label("Open this sermon's folder", systemImage: "folder") }
                }
                Button {
                    try? FileManager.default.createDirectory(at: Paths.output, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(Paths.output)
                } label: { Label("All sermons", systemImage: "folder.fill") }
            }
        }
        .padding(22)
        .frame(width: 680)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Pick up edits made in TextEdit or Finder while the app was in the background.
            model.refresh()
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    let detail: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(number)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.accentColor))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct DropZone: View {
    let title: String
    @Binding var url: URL?
    let types: [UTType]
    var disabled = false
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: url == nil ? "film" : "film.fill")
                .font(.system(size: 26))
                .foregroundStyle(url == nil ? Color.secondary : Color.accentColor)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                if let url {
                    Text(url.lastPathComponent).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Text(url.deletingLastPathComponent().path.replacingOccurrences(of: Paths.home.path, with: "~"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                } else {
                    Text(title).font(.body.weight(.medium))
                    Text("Drop it here, or click to choose").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if url != nil && !disabled {
                Button { url = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(targeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.45),
                              style: StrokeStyle(lineWidth: targeted ? 2 : 1.2, dash: url == nil ? [6, 4] : []))
        )
        .contentShape(Rectangle())
        .onTapGesture { if !disabled { choose() } }
        .dropDestination(for: URL.self) { urls, _ in
            guard !disabled, let u = urls.first(where: accepts) else { return false }
            url = u
            return true
        } isTargeted: { targeted = $0 && !disabled }
    }

    private func accepts(_ u: URL) -> Bool {
        guard let t = UTType(filenameExtension: u.pathExtension) else { return false }
        return types.contains { t.conforms(to: $0) }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.message = title
        if panel.runModal() == .OK, let u = panel.url { url = u }
    }
}

/// The looks on offer for the captions on the Spanish video (the names
/// `sermon_captions.py spanish --style` takes).
enum CaptionStyle: String, CaseIterable, Identifiable {
    case box, outline, yellow
    var id: Self { self }
    var title: String {
        switch self {
        case .box: "Box"
        case .outline: "Outline"
        case .yellow: "Yellow"
        }
    }
    var help: String {
        switch self {
        case .box: "White text on a see-through black box, like YouTube and TV. The easiest to read over a busy picture."
        case .outline: "White text with a thin black outline and no box, like Netflix and films."
        case .yellow: "Yellow text with a black outline, like broadcast TV and DVDs."
        }
    }
}

/// A small picture of a caption style, to click.
struct CaptionStyleTile: View {
    let style: CaptionStyle
    let selected: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack(alignment: .bottom) {
                    LinearGradient(colors: [Color(white: 0.55), Color(red: 0.3, green: 0.35, blue: 0.4)],
                                   startPoint: .top, endPoint: .bottom)
                    sample.padding(.bottom, 8)
                }
                .frame(width: 112, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 2.5 : 1))
                Text(style.title).font(.caption).foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.5)
        .help(style.help)
    }

    @ViewBuilder private var sample: some View {
        let text = Text("Caption text").font(.system(size: 12, weight: .bold))
        switch style {
        case .box:
            text.foregroundStyle(.white).padding(.horizontal, 3).background(Color.black.opacity(0.5))
        case .outline, .yellow:
            text.foregroundStyle(style == .yellow ? Color.yellow : .white)
                .shadow(color: .black, radius: 0, x: 1, y: 0).shadow(color: .black, radius: 0, x: -1, y: 0)
                .shadow(color: .black, radius: 0, x: 0, y: 1).shadow(color: .black, radius: 0, x: 0, y: -1)
                .shadow(color: .black.opacity(0.6), radius: 1, x: 1, y: 1)
        }
    }
}

/// A finished file: drag it out (to Finder, HeyGen, ProPresenter), or
/// double-click to open it.
struct FileTile: View {
    let url: URL
    let label: String
    var extra: (String, () -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.callout.weight(.medium)).lineLimit(1).fixedSize()
                Text(size).font(.caption).foregroundStyle(.secondary)
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            Menu {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Open") { NSWorkspace.shared.open(url) }
                if let extra { Button(extra.0, action: extra.1) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.35)))
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .help("Drag this out, or double-click to open")
    }

    private var size: String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

struct StatusArea: View {
    @ObservedObject var model: Model

    var body: some View {
        if model.job != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(model.stage).font(.callout)
                    Spacer()
                    Text("\(Int(model.progress * 100))%").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Button("Stop") { model.cancel() }
                }
                ProgressView(value: model.progress)
            }
        } else if let message = model.message {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: model.messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(model.messageIsError ? Color.red : Color.green)
                Text(message).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct SermonCaptionsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = Model()

    init() {
        // `--snapshot out.png [english] [spanish]` renders the window to a PNG and exits.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot-trim"), i + 2 < args.count {
            Snapshot.renderTrim(to: args[i + 1], video: args[i + 2], intro: args.dropFirst(i + 3).first)
            exit(0)
        }
        // `--preview-trim out.mov video in out intro outro introFade outroFade`
        // exports what the trim window plays, to check it against the save.
        if let i = args.firstIndex(of: "--preview-trim"), i + 8 < args.count {
            Snapshot.exportPreview(Array(args[(i + 1)...(i + 8)]))
            exit(0)
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshot.render(to: args[i + 1], english: args.dropFirst(i + 2).first,
                            spanish: args.dropFirst(i + 3).first)
            exit(0)
        }
    }

    var body: some Scene {
        Window("Sermon Captions", id: "main") {
            ContentView(model: model)
        }
        .windowResizability(.contentSize)

        Window(TrimEditor.title, id: "trim") {
            TrimWindow(model: model)
        }
        .defaultSize(width: 1180, height: 940)
    }
}

@MainActor
enum Snapshot {
    static func renderTrim(to path: String, video: String, intro: String? = nil) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let model = Model()
        model.sourceVideo = URL(fileURLWithPath: video)
        model.prepareTrim()
        guard let c = model.trim else { return }
        c.onChange = nil
        RunLoop.current.run(until: Date().addingTimeInterval(6))   // waveform + thumbnails
        c.setIn(83.2)
        c.setOut(2140)
        c.fade = true
        c.level = true
        RunLoop.current.run(until: Date().addingTimeInterval(5))   // loudness
        c.loadSuggestions(TrimSuggestions(
            starts: [TrimSuggestion(time: 83.1, room: 82.6, word: 83.6,
                                    why: "He starts with: Good morning, church. Welcome to the third service …"),
                     TrimSuggestion(time: 95, room: 94, word: 95.5, why: "Where the long stretch of talking starts: …")],
            ends: [TrimSuggestion(time: 2140.2, room: 2141, word: 2139.7,
                                  why: "His sign-off: God bless you, have a great week.")]))
        c.seek(84)
        c.addSection()
        if let id = c.sections.first?.id { c.setChoice(id, .down) }
        c.seek(2100)
        c.addSection()
        c.seek(2139)
        if let id = c.sections.last?.id { c.setSectionEnd(id) }
        if let intro { Task { _ = await c.chooseClip(.intro, URL(fileURLWithPath: intro), remember: false) } }
        c.seek(84)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let host = NSHostingView(rootView: TrimEditor(model: model, c: c)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame.size = CGSize(width: 1180, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    static func exportPreview(_ a: [String]) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let model = Model()
        model.sourceVideo = URL(fileURLWithPath: a[1])
        model.prepareTrim()
        guard let c = model.trim else { return }
        c.onChange = nil
        while !c.ready { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        c.setOut(c.duration)
        c.setIn(Double(a[2])!)
        c.setOut(Double(a[3])!)
        c.fade = true
        c.autoColor = true
        c.level = true
        var set = false
        Task {
            for (slot, path) in [(ClipSlot.intro, a[4]), (.outro, a[5])] {
                _ = await c.chooseClip(slot, path == "-" ? nil : URL(fileURLWithPath: path), remember: false)
            }
            c.setCrossfade(.intro, Double(a[6])!, remember: false)
            c.setCrossfade(.outro, Double(a[7])!, remember: false)
            _ = await c.ensureLevel()
            _ = await c.ensureColor()
            set = true
        }
        while !set { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        RunLoop.current.run(until: Date().addingTimeInterval(4))   // clip loudness, player rebuilt
        c.preview.update {
            $0.playing = true
            $0.showClips = true
        }
        guard let item = c.player.currentItem,
              let session = AVAssetExportSession(asset: item.asset, presetName: AVAssetExportPresetHighestQuality)
        else { print("EXPORT no player item"); return }
        let out = URL(fileURLWithPath: a[0])
        try? FileManager.default.removeItem(at: out)
        session.outputURL = out
        session.outputFileType = .mov
        session.videoComposition = item.videoComposition
        session.audioMix = item.audioMix
        print("ITEM", item.asset is AVComposition, item.videoComposition != nil, c.savedSeconds)
        print("TRIM", (c.clipArgs + [String(format: "%.6f", c.exportStart), String(format: "%.6f", c.exportLength),
                                     c.levelArg, c.colorArg]).joined(separator: " "))
        var done = false
        session.exportAsynchronously { done = true }
        while !done { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        print("EXPORT", session.status.rawValue, session.error.map { "\($0)" } ?? "")
    }

    static func render(to path: String, english: String?, spanish: String?) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let model = Model()
        model.englishVideo = english.map { URL(fileURLWithPath: $0) }
        model.spanishVideo = spanish.map { URL(fileURLWithPath: $0) }
        if english != nil && spanish != nil { model.show("The Spanish video with English captions is ready (5 min 12 sec).") }
        let host = NSHostingView(rootView: ContentView(model: model)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
