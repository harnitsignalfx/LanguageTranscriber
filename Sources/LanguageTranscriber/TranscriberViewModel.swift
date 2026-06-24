import Foundation
import SwiftUI
import Combine
import NaturalLanguage

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

// MARK: - High-churn stores (split off the view model)
//
// The fix for sustained high CPU during live transcription: split the monolith into
// separate ObservableObjects. With a Combine ObservableObject, ANY @Published mutation
// fires objectWillChange and invalidates EVERY view that injects that object — regardless
// of which property the view's body reads (per-property observation only exists with the
// macOS-14 @Observable macro, which this app cannot use). So high-churn state living on the
// same object that ContentView observes forced ContentView.body (and its toolbar Pickers)
// to re-render on every translation delta / 4 Hz tick / pair flush.
//
// We move the HIGH-CHURN published state into dedicated @MainActor ObservableObjects, each
// observed ONLY by its leaf view. TranscriberViewModel OWNS them as plain `let` properties
// (NOT @Published) — reading a plain `let` does NOT subscribe the reader to that store's
// objectWillChange. TranscriberViewModel keeps ONLY low-churn control state @Published.
//
// INVARIANT: after this split, ContentView's objectWillChange subscription (to the VM) fires
// ONLY on low-churn control changes. A translation delta fires objectWillChange on `liveText`
// only → re-renders ONLY LivePaneView. A 4 Hz diagnostics tick fires on `diagnostics` only →
// re-renders ONLY StatusBarView. A pair flush fires on `transcript` only → re-renders ONLY
// HistoryContainerView (then `.equatable()` gates the list). ContentView.body and the toolbar
// Pickers do NOT re-render during a steady-state session.

/// High-churn live caption text. Observed ONLY by `LivePaneView`. Updated IMMEDIATELY per
/// translation delta (no throttling) so the live transcript has zero added latency.
@MainActor
final class LiveTextStore: ObservableObject {
    @Published var english = ""
    @Published var other = ""
}

/// Diagnostic mirrors updated at ~4 Hz by the VM's diagnostics timer. Observed ONLY by
/// `StatusBarView`.
@MainActor
final class DiagnosticsStore: ObservableObject {
    @Published var audioBytesSent: Int64 = 0
    @Published var lastAudioAt: Date?
    @Published var englishDeltasReceived: Int = 0
    @Published var otherDeltasReceived: Int = 0
    @Published var eventCounts: [String: Int] = [:]
    @Published var transcriptionStatus: String = "off"
    @Published var transcriptionEventCounts: [String: Int] = [:]
    @Published var transcriptionCharsReceived: Int = 0
}

/// Finalized utterance pairs. Observed ONLY by `HistoryContainerView`.
@MainActor
final class TranscriptStore: ObservableObject {
    /// Single ordered list of finalized utterance pairs. Each pair carries both translations
    /// of the same audio segment so the EN and OTHER columns are always row-aligned.
    @Published var pairs: [UtterancePair] = []
}

@MainActor
final class TranscriberViewModel: ObservableObject {
    // MARK: - High-churn stores (owned as plain `let`s — NOT @Published)
    //
    // Reading these from ContentView does NOT subscribe ContentView to their changes; the
    // leaf views take them as @ObservedObject so each store's mutations re-render only that
    // leaf view.
    let liveText = LiveTextStore()
    let diagnostics = DiagnosticsStore()
    let transcript = TranscriptStore()

    // MARK: - Published state (LOW-CHURN control state ONLY)

    @Published var statusText: String = "Idle"
    @Published var statusIsError: Bool = false
    @Published var isRunning: Bool = false
    @Published var selectedSource: AudioSource = .both
    @Published var configLoaded: Bool = false
    @Published var configIssue: String?
    @Published var apiKeySource: AppConfig.APIKeySource = .none

    /// Low-churn mirror of "are there any committed pairs". ContentView.body's toolbar +
    /// column headers read THIS (for Clear/Copy disabled states) instead of `pairs` directly,
    /// so ContentView.body is NOT invalidated on every pair flush — it flips only on the
    /// empty <-> non-empty transition (stable during a session). Without this, every flush
    /// re-ran ContentView.body and rebuilt the toolbar's Pickers (expensive 20-item menu).
    /// (We deliberately do NOT mirror live text: it toggles every utterance, which would
    /// re-introduce the churn — the Clear button keys off hasPairs alone.)
    ///
    /// `pairs` now lives on `transcript` (a separate store), so `transcript.pairs.didSet`
    /// cannot reach this property. The VM instead calls `refreshHasPairs()` right after every
    /// `transcript.pairs` mutation (append in flush, reset in clearTranscript). `hasPairs`
    /// stays on the VM (low-churn, drives the toolbar) — that's intentional.
    @Published var hasPairs: Bool = false

    private func refreshHasPairs() {
        let has = !transcript.pairs.isEmpty
        if has != hasPairs { hasPairs = has }
    }

    @Published var selectedOtherLanguage: String = "pt"
    let availableLanguages: [Language] = Languages.common

    // MARK: - User-editable settings (persisted to UserDefaults)
    //
    // Effective-value precedence is resolved once in `loadConfig()`: UserDefaults override
    // (if the user has set one) → config.json (AppConfig) → hardcoded default. After that,
    // every change here writes straight back to UserDefaults via `didSet`.
    //
    // The two timing values are read LIVE in `scheduleFlush()`, so edits apply without
    // restarting a session. `detectSourceLanguage` and `transcriptionModel` are read at
    // `start()`, so they apply on the next Start.

    /// While true, didSet observers skip writing to UserDefaults. Set during the initial
    /// `applyEffectiveSettings()` so resolving the effective value (which may come from
    /// config.json) doesn't accidentally persist it as a user override.
    private var isApplyingEffectiveSettings = false

    @Published var segmentSilenceMs: Int = 1500 {
        didSet { if !isApplyingEffectiveSettings { SettingsStore.segmentSilenceMs = segmentSilenceMs } }
    }
    @Published var sentenceFlushMs: Int = 700 {
        didSet { if !isApplyingEffectiveSettings { SettingsStore.sentenceFlushMs = sentenceFlushMs } }
    }
    @Published var detectSourceLanguage: Bool = true {
        didSet { if !isApplyingEffectiveSettings { SettingsStore.detectSourceLanguage = detectSourceLanguage } }
    }
    @Published var transcriptionModel: String = "gpt-realtime-whisper" {
        didSet { if !isApplyingEffectiveSettings { SettingsStore.transcriptionModel = transcriptionModel } }
    }

    /// Available transcription models for the Settings picker (label, value).
    static let transcriptionModelOptions: [(label: String, value: String)] = [
        ("gpt-realtime-whisper", "gpt-realtime-whisper"),
        ("gpt-4o-transcribe", "gpt-4o-transcribe"),
        ("gpt-4o-mini-transcribe", "gpt-4o-mini-transcribe"),
        ("whisper-1", "whisper-1")
    ]

    // Diagnostics
    @Published var micPermission: PermissionState = .undetermined
    @Published var screenPermission: PermissionState = .undetermined

    // High-frequency diagnostic counters. The UI reads ONLY the @Published mirrors below,
    // which a single ~4 Hz timer copies from these plain-storage accumulators. The raw
    // counters are mutated synchronously on the main actor at full audio/delta rate, but
    // they are NOT @Published, so updating them does not invalidate the SwiftUI view tree.
    // This keeps the status bar from forcing ContentView.body (and the history list) to
    // re-diff on every audio frame (~50/s) and every translation delta.
    //
    // Live transcript text (`liveEnglish` / `liveOther`) is deliberately NOT coalesced —
    // it stays @Published and updates immediately per delta so there is zero added latency.
    private var rawAudioBytesSent: Int64 = 0
    private var rawLastAudioAt: Date?
    private var rawEnglishDeltasReceived: Int = 0
    private var rawOtherDeltasReceived: Int = 0
    private var rawEventCounts: [String: Int] = [:]
    private var rawTranscriptionEventCounts: [String: Int] = [:]
    private var rawTranscriptionCharsReceived: Int = 0

    // The @Published diagnostic mirrors the status bar binds to now live on `diagnostics`
    // (DiagnosticsStore), updated at ~4 Hz by `publishDiagnostics()`. Mutating them fires
    // objectWillChange on `diagnostics` only → re-renders ONLY StatusBarView.

    /// Copies the raw diagnostic accumulators into their @Published mirrors at ~4 Hz.
    private var diagnosticsTimer: Timer?

    // MARK: - Internal

    private var config: AppConfig?

    // Two realtime sessions: one targeting English, one targeting the selected other language.
    // Both receive the same audio stream (a mixer-merged stream in Both mode).
    private var englishClient: RealtimeClient?
    private var otherClient: RealtimeClient?

    // Optional third session — transcription-only with auto language detection. Its output is
    // never shown directly; we only use it to figure out which side of the pair the speaker
    // actually used, then tag the pair so the UI can highlight that cell.
    private var transcriptionClient: TranscriptionClient?
    private var liveTranscription: String = ""

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
            Task { @MainActor [weak self] in self?.refreshPermissions() }
        }
    }

    func refreshPermissions() {
        // Only assign when changed — @Published fires objectWillChange on every assignment
        // even if the value is identical, which would re-run ContentView.body every 2s for
        // no reason.
        let mic = Permissions.microphone()
        if mic != micPermission { micPermission = mic }
        let screen = Permissions.screenRecording()
        if screen != screenPermission { screenPermission = screen }
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
            applyEffectiveSettings(config: cfg)

        case .notFound(let searched, let parseErrors):
            configLoaded = false
            apiKeySource = .none
            applyEffectiveSettings(config: nil)
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

    /// Resolve the effective value of each editable setting with precedence:
    /// UserDefaults override (if set) → config.json (AppConfig) → hardcoded default.
    /// Runs with `isApplyingEffectiveSettings` set so this resolution is not itself
    /// written back to UserDefaults.
    private func applyEffectiveSettings(config: AppConfig?) {
        isApplyingEffectiveSettings = true
        defer { isApplyingEffectiveSettings = false }

        segmentSilenceMs   = SettingsStore.segmentSilenceMs   ?? config?.resolvedSegmentSilenceMs   ?? 1500
        sentenceFlushMs    = SettingsStore.sentenceFlushMs    ?? config?.resolvedSentenceFlushMs    ?? 700
        detectSourceLanguage = SettingsStore.detectSourceLanguage ?? config?.resolvedDetectSourceLanguage ?? true
        transcriptionModel = SettingsStore.transcriptionModel ?? config?.resolvedTranscriptionModel ?? "gpt-realtime-whisper"
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
        // Reset both the raw accumulators and their published mirrors so a fresh session
        // starts from zero in the status bar.
        rawAudioBytesSent = 0
        rawLastAudioAt = nil
        rawEnglishDeltasReceived = 0
        rawOtherDeltasReceived = 0
        rawEventCounts = [:]
        diagnostics.audioBytesSent = 0
        diagnostics.lastAudioAt = nil
        diagnostics.englishDeltasReceived = 0
        diagnostics.otherDeltasReceived = 0
        diagnostics.eventCounts = [:]
        startDiagnosticsTimer()

        let lang = selectedOtherLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        let otherLang = lang.isEmpty ? "pt" : lang

        // Spin up the two translation sessions.
        englishClient = makeClient(config: config, target: "en")
        otherClient   = makeClient(config: config, target: otherLang)
        englishClient?.connect()
        otherClient?.connect()

        // Spin up the source-language transcription session if enabled. Its sole job is
        // to tell us which language the speaker actually used so the UI can tint the
        // matching cell.
        if detectSourceLanguage {
            diagnostics.transcriptionStatus = "connecting"
            rawTranscriptionEventCounts = [:]
            rawTranscriptionCharsReceived = 0
            diagnostics.transcriptionEventCounts = [:]
            diagnostics.transcriptionCharsReceived = 0

            let tc = TranscriptionClient(apiKey: config.apiKey,
                                         model: transcriptionModel)
            tc.onState = { [weak self] state in
                Task { @MainActor [weak self] in
                    switch state {
                    case .connecting:   self?.diagnostics.transcriptionStatus = "connecting"
                    case .connected:    self?.diagnostics.transcriptionStatus = "connected"
                    case .disconnected: self?.diagnostics.transcriptionStatus = "off"
                    case .failed(let m): self?.diagnostics.transcriptionStatus = "failed: \(m)"
                    }
                }
            }
            tc.onPartialTranscript = { [weak self] delta in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.liveTranscription += delta
                    self.rawTranscriptionCharsReceived &+= delta.count
                }
            }
            tc.onFinalTranscript = { [weak self] text in
                Task { @MainActor [weak self] in
                    // Accumulator gets the final text too (covers the case where deltas
                    // dropped and the completed event is the first time we see anything).
                    guard let self else { return }
                    if self.liveTranscription.isEmpty {
                        self.liveTranscription = text
                        self.rawTranscriptionCharsReceived &+= text.count
                    }
                }
            }
            tc.onError = { [weak self] err in
                // %{public}@ keeps the message readable in `log show`; the default %@
                // gets redacted as <private> on macOS.
                NSLog("[LanguageTranscriber] transcription error: %{public}@", err)
                Task { @MainActor [weak self] in
                    self?.setStatus("Transcription: \(err)", isError: true)
                }
            }
            tc.onAnyEvent = { [weak self] type in
                Task { @MainActor [weak self] in
                    self?.rawTranscriptionEventCounts[type, default: 0] += 1
                }
            }
            tc.connect()
            transcriptionClient = tc
        } else {
            diagnostics.transcriptionStatus = "off"
        }

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

        englishClient?.disconnect();      englishClient = nil
        otherClient?.disconnect();        otherClient = nil
        transcriptionClient?.disconnect(); transcriptionClient = nil

        flushLive()

        // Final flush of the diagnostic accumulators so the status bar reflects the true
        // totals after the last audio frame, then stop the coalescing timer.
        publishDiagnostics()
        stopDiagnosticsTimer()

        isRunning = false
        setStatus("Stopped", isError: false)
    }

    func clearTranscript() {
        transcript.pairs = []
        refreshHasPairs()
        liveText.english = ""
        liveText.other = ""
        liveTranscription = ""
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
            Task { @MainActor [weak self] in self?.handleClientState(state) }
        }
        c.onTargetDelta = { [weak self] delta in
            Task { @MainActor [weak self] in self?.handleTargetDelta(delta, isEnglish: isEnglish) }
        }
        c.onError = { [weak self] err in
            Task { @MainActor [weak self] in self?.setStatus(err, isError: true) }
        }
        if isEnglish {
            c.onAnyEvent = { [weak self] type in
                Task { @MainActor [weak self] in self?.rawEventCounts[type, default: 0] += 1 }
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
            Task { @MainActor [weak self] in self?.setStatus(err, isError: true) }
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
            Task { @MainActor [weak self] in self?.setStatus(err, isError: true) }
        }
        self.sysAudio = s
        Task { await s.start() }
    }

    private func fanOutAudio(_ data: Data) {
        englishClient?.sendAudio(data)
        otherClient?.sendAudio(data)
        transcriptionClient?.sendAudio(data)
        // Accumulate into plain (non-@Published) storage; the ~4 Hz diagnostics timer
        // publishes it. This used to write @Published props on every audio chunk (~50/s).
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.rawAudioBytesSent &+= Int64(data.count)
            self.rawLastAudioAt = Date()
        }
    }

    // MARK: - Delta handling

    private func handleTargetDelta(_ delta: String, isEnglish: Bool) {
        // liveEnglish / liveOther are @Published and update IMMEDIATELY — no coalescing,
        // so the live transcript has zero added latency. Only the delta COUNTERS (status
        // bar diagnostics) are accumulated into plain storage and published at ~4 Hz.
        if isEnglish {
            rawEnglishDeltasReceived += 1
            liveText.english += delta
        } else {
            rawOtherDeltasReceived += 1
            liveText.other += delta
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        flushWork?.cancel()
        // Sentence-aware debounce: once the buffers end on sentence-terminating punctuation,
        // use a much shorter quiet window so we break paragraphs at sentence boundaries
        // instead of letting them run on.
        //
        // We only shorten the window when EVERY non-empty column looks sentence-complete,
        // and at least one column has content. If English finished a sentence but the other
        // column is still mid-translation (non-empty, no terminator yet), we keep the full
        // window so we don't commit a truncated counterpart.
        let enReady = liveText.english.isEmpty || endsSentence(liveText.english)
        let otherReady = liveText.other.isEmpty || endsSentence(liveText.other)
        let hasContent = !liveText.english.isEmpty || !liveText.other.isEmpty
        let atSentenceEnd = hasContent && enReady && otherReady
        // Read the live, UserDefaults-aware settings so timing edits apply without restarting.
        let ms = atSentenceEnd ? sentenceFlushMs : segmentSilenceMs
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in self?.flushLive() }
        }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: work)
    }

    /// True when the trimmed text ends on a sentence terminator. Covers Latin (. ! ? …),
    /// CJK (。！？), and Devanagari (।) so it works across the supported languages.
    private func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return ".!?…。！？।".contains(last)
    }

    private func flushLive() {
        let en = liveText.english.trimmingCharacters(in: .whitespacesAndNewlines)
        let other = liveText.other.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = liveTranscription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !en.isEmpty || !other.isEmpty else {
            liveTranscription = ""
            return
        }

        // Light dedup: drop near-identical paragraphs landing within ~6 s. Catches the
        // common case of speaker bleed (Both mode without headphones) producing two
        // transcripts of the same utterance.
        if isDuplicateOfRecent(en: en, other: other) {
            liveText.english = ""
            liveText.other = ""
            liveTranscription = ""
            return
        }

        transcript.pairs.append(UtterancePair(
            id: UUID().uuidString,
            english: en,
            other: other,
            originalLanguage: classifySourceLanguage(source)
        ))
        refreshHasPairs()
        lastFlushAt = Date()
        liveText.english = ""
        liveText.other = ""
        liveTranscription = ""
    }

    /// Detect the dominant language of the source-language transcript via Apple's
    /// `NLLanguageRecognizer`. Map English → `.english`, the picked other language → `.other`,
    /// anything else (including empty/too-short transcripts) → `.unknown`.
    private func classifySourceLanguage(_ text: String) -> OriginalLanguage {
        guard text.count >= 5 else { return .unknown }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let lang = recognizer.dominantLanguage else { return .unknown }
        let code = lang.rawValue
        if code == "en" { return .english }
        if code.caseInsensitiveCompare(selectedOtherLanguage) == .orderedSame { return .other }
        return .unknown
    }

    private func isDuplicateOfRecent(en: String, other: String) -> Bool {
        guard let lastFlushAt, Date().timeIntervalSince(lastFlushAt) < 6.0 else { return false }
        // Only dedup substantial utterances. Short ones ("Yes.", "Okay", "Right") are
        // legitimately repeated in real conversation, and with sentence-aware flushing
        // producing shorter paragraphs, deduping them would silently eat real speech.
        // Echo bleed (the case this guards against) is almost always full sentences.
        let enWords = normalizeForCompare(en).count
        let otherWords = normalizeForCompare(other).count
        guard enWords >= 4 || otherWords >= 4 else { return false }
        for p in transcript.pairs.suffix(3) {
            if enWords >= 4 && jaccardSimilarity(en, p.english) >= 0.82 { return true }
            if otherWords >= 4 && jaccardSimilarity(other, p.other) >= 0.82 { return true }
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

    // MARK: - Diagnostics coalescing

    /// Start the ~4 Hz timer that flushes raw diagnostic counters into their @Published
    /// mirrors. Idempotent: tears down any existing timer first.
    private func startDiagnosticsTimer() {
        diagnosticsTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.publishDiagnostics() }
        }
        diagnosticsTimer = t
    }

    private func stopDiagnosticsTimer() {
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
    }

    /// Copy raw accumulators into the @Published mirrors, but only assign properties whose
    /// value actually changed — an unchanged @Published assignment still fires objectWillChange,
    /// so guarding keeps the UI from invalidating when nothing moved.
    private func publishDiagnostics() {
        if diagnostics.audioBytesSent != rawAudioBytesSent { diagnostics.audioBytesSent = rawAudioBytesSent }
        if diagnostics.lastAudioAt != rawLastAudioAt { diagnostics.lastAudioAt = rawLastAudioAt }
        if diagnostics.englishDeltasReceived != rawEnglishDeltasReceived { diagnostics.englishDeltasReceived = rawEnglishDeltasReceived }
        if diagnostics.otherDeltasReceived != rawOtherDeltasReceived { diagnostics.otherDeltasReceived = rawOtherDeltasReceived }
        if diagnostics.eventCounts != rawEventCounts { diagnostics.eventCounts = rawEventCounts }
        if diagnostics.transcriptionEventCounts != rawTranscriptionEventCounts { diagnostics.transcriptionEventCounts = rawTranscriptionEventCounts }
        if diagnostics.transcriptionCharsReceived != rawTranscriptionCharsReceived { diagnostics.transcriptionCharsReceived = rawTranscriptionCharsReceived }
    }

    // MARK: - Status

    private func setStatus(_ text: String, isError: Bool) {
        statusText = text
        statusIsError = isError
    }
}
