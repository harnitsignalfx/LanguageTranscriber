import Foundation
import SwiftUI
import Combine

enum AudioSource: String, CaseIterable, Identifiable {
    case microphone = "Microphone"
    case systemAudio = "System Audio (video calls)"
    case both = "Microphone + System Audio"
    var id: String { rawValue }
    var shortLabel: String {
        switch self {
        case .microphone:  return "Mic"
        case .systemAudio: return "System"
        case .both:        return "Both"
        }
    }
    var symbolName: String {
        switch self {
        case .microphone:  return "mic.fill"
        case .systemAudio: return "speaker.wave.2.fill"
        case .both:        return "mic.and.signal.meter.fill"
        }
    }
    var usesMic: Bool {
        switch self {
        case .microphone, .both: return true
        case .systemAudio:       return false
        }
    }
    var usesScreen: Bool {
        switch self {
        case .systemAudio, .both: return true
        case .microphone:         return false
        }
    }
}

@MainActor
final class TranscriberViewModel: ObservableObject {
    // MARK: - Published state

    @Published var statusText: String = "Idle"
    @Published var statusIsError: Bool = false
    @Published var isRunning: Bool = false
    @Published var selectedSource: AudioSource = .both
    @Published var configLoaded: Bool = false
    @Published var configIssue: String?
    @Published var apiKeySource: AppConfig.APIKeySource = .none

    /// Single ordered list of finalized utterance pairs. Each pair carries both translations
    /// of the same audio segment so the EN and OTHER columns are always row-aligned.
    @Published var pairs: [UtterancePair] = []
    @Published var liveEnglish: String = ""
    @Published var liveOther: String = ""

    @Published var selectedOtherLanguage: String = "pt"
    let availableLanguages: [Language] = Languages.common

    // Diagnostics
    @Published var micPermission: PermissionState = .undetermined
    @Published var screenPermission: PermissionState = .undetermined
    @Published var audioBytesSent: Int64 = 0
    @Published var lastAudioAt: Date?
    @Published var englishDeltasReceived: Int = 0
    @Published var otherDeltasReceived: Int = 0
    @Published var eventCounts: [String: Int] = [:]

    // MARK: - Internal

    private var config: AppConfig?

    // Two realtime sessions: one targeting English, one targeting the selected other language.
    // Both receive the same audio stream (a mixer-merged stream in Both mode).
    private var englishClient: RealtimeClient?
    private var otherClient: RealtimeClient?

    private var mic: MicrophoneCapture?
    private var sysAudio: Any?
    private var mixer: AudioMixer?

    private var flushWork: DispatchWorkItem?
    private var lastFlushAt: Date?

    private var permissionPollTimer: Timer?

    init() {
        loadConfig()
        refreshPermissions()
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
    }

    func refreshPermissions() {
        micPermission = Permissions.microphone()
        screenPermission = Permissions.screenRecording()
    }

    // MARK: - Config

    func loadConfig() {
        switch AppConfig.load() {
        case .loaded(let cfg, let source):
            config = cfg
            configLoaded = true
            configIssue = nil
            apiKeySource = source
            let initialCode = (cfg.otherLanguage?.isEmpty == false) ? cfg.otherLanguage! : "pt"
            selectedOtherLanguage = initialCode

        case .notFound(let searched, let parseErrors):
            configLoaded = false
            apiKeySource = .none
            var msg = "No OpenAI API key found.\n\n"
            msg += "Easiest fix: open Settings (⌘ ,) and paste your API key.\n"
            msg += "Alternatives: set OPENAI_API_KEY env var, or create config.json with {\"apiKey\": \"sk-…\"} at one of:\n"
            for p in searched { msg += "  • \(p)\n" }
            if !parseErrors.isEmpty {
                msg += "\nFiles that exist but failed to parse:\n"
                for (path, err) in parseErrors {
                    msg += "  • \(path)\n    \(err)\n"
                }
            }
            configIssue = msg
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard let config else {
            setStatus(configIssue ?? "Missing config", isError: true)
            return
        }
        guard !isRunning else { return }

        refreshPermissions()
        clearTranscript()
        audioBytesSent = 0
        lastAudioAt = nil
        englishDeltasReceived = 0
        otherDeltasReceived = 0
        eventCounts = [:]

        let lang = selectedOtherLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        let otherLang = lang.isEmpty ? "pt" : lang

        // Spin up the two translation sessions.
        englishClient = makeClient(config: config, target: "en")
        otherClient   = makeClient(config: config, target: otherLang)
        englishClient?.connect()
        otherClient?.connect()

        isRunning = true
        setStatus("Connecting…", isError: false)

        switch selectedSource {
        case .microphone:
            startMicrophone(routedToMixer: false)
        case .systemAudio:
            if #available(macOS 13.0, *) {
                startSystemAudio(routedToMixer: false)
            } else {
                setStatus("System audio capture requires macOS 13 or later.", isError: true)
                stop()
            }
        case .both:
            if #available(macOS 13.0, *) {
                let m = AudioMixer()
                m.onMixedPCM16 = { [weak self] data in self?.fanOutAudio(data) }
                m.start()
                self.mixer = m
                startMicrophone(routedToMixer: true)
                startSystemAudio(routedToMixer: true)
            } else {
                setStatus("Combined mic + system audio requires macOS 13 or later.", isError: true)
                stop()
            }
        }
    }

    func stop() {
        mic?.stop()
        mic = nil
        if #available(macOS 13.0, *), let s = sysAudio as? SystemAudioCapture {
            Task { await s.stop() }
        }
        sysAudio = nil
        mixer?.stop()
        mixer = nil

        englishClient?.disconnect(); englishClient = nil
        otherClient?.disconnect();   otherClient = nil

        flushLive()

        isRunning = false
        setStatus("Stopped", isError: false)
    }

    func clearTranscript() {
        pairs = []
        liveEnglish = ""
        liveOther = ""
        flushWork?.cancel(); flushWork = nil
        lastFlushAt = nil
    }

    // MARK: - Session wiring

    private func makeClient(config: AppConfig, target: String) -> RealtimeClient {
        let c = RealtimeClient(apiKey: config.apiKey,
                               model: config.resolvedModel,
                               targetLanguage: target)
        let isEnglish = (target == "en")
        c.onState = { [weak self] state in
            Task { @MainActor in self?.handleClientState(state) }
        }
        c.onTargetDelta = { [weak self] delta in
            Task { @MainActor in self?.handleTargetDelta(delta, isEnglish: isEnglish) }
        }
        c.onError = { [weak self] err in
            Task { @MainActor in self?.setStatus(err, isError: true) }
        }
        if isEnglish {
            c.onAnyEvent = { [weak self] type in
                Task { @MainActor in self?.eventCounts[type, default: 0] += 1 }
            }
        }
        return c
    }

    private func handleClientState(_ state: RealtimeClient.ConnectionState) {
        switch state {
        case .connecting:
            setStatus("Connecting…", isError: false)
        case .connected:
            setStatus("Listening", isError: false)
        case .disconnected:
            if !isRunning { setStatus("Disconnected", isError: false) }
        case .failed(let msg):
            setStatus("Connection failed: \(msg)", isError: true)
            isRunning = false
        }
    }

    // MARK: - Audio capture

    private func startMicrophone(routedToMixer: Bool) {
        let m = MicrophoneCapture()
        m.onAudio = { [weak self] data in
            guard let self else { return }
            if routedToMixer {
                self.mixer?.feedMic(data)
            } else {
                self.fanOutAudio(data)
            }
        }
        m.onError = { [weak self] err in
            Task { @MainActor in self?.setStatus(err, isError: true) }
        }
        m.start()
        self.mic = m
    }

    @available(macOS 13.0, *)
    private func startSystemAudio(routedToMixer: Bool) {
        let s = SystemAudioCapture()
        s.onAudio = { [weak self] data in
            guard let self else { return }
            if routedToMixer {
                self.mixer?.feedSystem(data)
            } else {
                self.fanOutAudio(data)
            }
        }
        s.onError = { [weak self] err in
            Task { @MainActor in self?.setStatus(err, isError: true) }
        }
        self.sysAudio = s
        Task { await s.start() }
    }

    private func fanOutAudio(_ data: Data) {
        englishClient?.sendAudio(data)
        otherClient?.sendAudio(data)
        Task { @MainActor in
            self.audioBytesSent &+= Int64(data.count)
            self.lastAudioAt = Date()
        }
    }

    // MARK: - Delta handling

    private func handleTargetDelta(_ delta: String, isEnglish: Bool) {
        if isEnglish {
            englishDeltasReceived += 1
            liveEnglish += delta
        } else {
            otherDeltasReceived += 1
            liveOther += delta
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        flushWork?.cancel()
        let ms = config?.resolvedSegmentSilenceMs ?? 1500
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.flushLive() }
        }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: work)
    }

    private func flushLive() {
        let en = liveEnglish.trimmingCharacters(in: .whitespacesAndNewlines)
        let other = liveOther.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !en.isEmpty || !other.isEmpty else { return }

        // Light dedup: drop near-identical paragraphs landing within ~6 s. Catches the
        // common case of speaker bleed (Both mode without headphones) producing two
        // transcripts of the same utterance.
        if isDuplicateOfRecent(en: en, other: other) {
            liveEnglish = ""
            liveOther = ""
            return
        }

        pairs.append(UtterancePair(id: UUID().uuidString, english: en, other: other))
        lastFlushAt = Date()
        liveEnglish = ""
        liveOther = ""
    }

    private func isDuplicateOfRecent(en: String, other: String) -> Bool {
        guard let lastFlushAt, Date().timeIntervalSince(lastFlushAt) < 6.0 else { return false }
        for p in pairs.suffix(3) {
            if !en.isEmpty && jaccardSimilarity(en, p.english) >= 0.82 { return true }
            if !other.isEmpty && jaccardSimilarity(other, p.other) >= 0.82 { return true }
        }
        return false
    }

    private func jaccardSimilarity(_ a: String, _ b: String) -> Double {
        let setA = normalizeForCompare(a)
        let setB = normalizeForCompare(b)
        guard !setA.isEmpty, !setB.isEmpty else { return 0 }
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        return Double(intersection) / Double(union)
    }

    private func normalizeForCompare(_ text: String) -> Set<String> {
        let lower = text.lowercased()
        let scalars = lower.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " "
        }
        let cleaned = String(String.UnicodeScalarView(scalars))
        return Set(cleaned.split(separator: " ", omittingEmptySubsequences: true).map(String.init))
    }

    // MARK: - Status

    private func setStatus(_ text: String, isError: Bool) {
        statusText = text
        statusIsError = isError
    }
}
