import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var vm: TranscriberViewModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if !vm.configLoaded {
                ConfigBanner(message: vm.configIssue ?? "")
            }
            transcriptArea
            // Isolated subview observing the DiagnosticsStore (a plain `let` on the VM, read
            // here WITHOUT subscribing ContentView to it). A 4 Hz diagnostics tick fires
            // objectWillChange on `diagnostics` only → re-renders ONLY this bar, never
            // ContentView.body. The low-churn status/permission values are read from the VM
            // via @EnvironmentObject inside StatusBarView.
            StatusBarView(diagnostics: vm.diagnostics)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 14) {
            Picker("", selection: $vm.selectedSource) {
                ForEach(AudioSource.allCases) { src in
                    Label(src.shortLabel, systemImage: src.symbolName).tag(src)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
            .disabled(vm.isRunning)

            Divider().frame(height: 22)

            HStack(spacing: 6) {
                Image(systemName: "globe").foregroundStyle(.secondary)
                Picker("", selection: $vm.selectedOtherLanguage) {
                    ForEach(vm.availableLanguages) { lang in
                        Text(lang.displayName).tag(lang.code)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 140)
                .disabled(vm.isRunning)
            }

            Spacer()

            Button {
                if vm.isRunning { vm.stop() } else { vm.start() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: vm.isRunning ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                    Text(vm.isRunning ? "Stop" : "Start").fontWeight(.semibold)
                }
                .frame(minWidth: 70)
            }
            .buttonStyle(.borderedProminent)
            .tint(vm.isRunning ? .red : .accentColor)
            .controlSize(.large)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!vm.configLoaded)

            Button { vm.clearTranscript() } label: {
                Image(systemName: "eraser").font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
            .help("Clear transcript")
            // Enabled whenever a session is running OR there are committed pairs — both are
            // low-churn (isRunning flips only on start/stop; hasPairs only empty<->non-empty).
            // We intentionally do NOT read live text here: it toggles every utterance and would
            // re-run ContentView.body a few times/sec, rebuilding the toolbar's Pickers. While
            // running, Clear stays enabled so the user can wipe in-flight live text too.
            .disabled(!vm.isRunning && !vm.hasPairs)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
    }

    // MARK: - Transcript area

    private var transcriptArea: some View {
        let otherLang = Languages.find(vm.selectedOtherLanguage)
        return VStack(spacing: 0) {
            // Column headers — pinned to top of the transcript area. fixedSize on the
            // vertical axis stops the HStack from claiming any flex space.
            HStack(spacing: 0) {
                columnHeader(title: otherLang.displayName,
                             subtitle: otherLang.code.uppercased(),
                             accent: .indigo,
                             copyAction: { copyAllOther() })
                Divider()
                columnHeader(title: "English",
                             subtitle: "EN",
                             accent: .blue,
                             copyAction: { copyAllEnglish() })
            }
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            // History fills all the space between the headers and the live pane.
            // HistoryContainerView observes the TranscriptStore (a plain `let` on the VM, read
            // here WITHOUT subscribing ContentView to it) — so a pair flush fires
            // objectWillChange on `transcript` only, re-rendering the container + the
            // (equatable) list, NOT ContentView.body. If ContentView.body read the pairs here,
            // every flush would rebuild the toolbar's Pickers (the expensive 20-item language
            // menu). The container + separate store severs that.
            HistoryContainerView(transcript: vm.transcript, otherLanguage: vm.selectedOtherLanguage)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Live pane (fixed) + breathing room before the status bar. The padding lives
            // on the live pane itself so the surrounding view doesn't grow. Isolated in its
            // own View struct (LivePaneView) that observes the LiveTextStore (a plain `let` on
            // the VM, read here WITHOUT subscribing ContentView to it) — a translation delta
            // fires objectWillChange on `liveText` only, re-rendering ONLY the live pane, not
            // ContentView.body. `isRunning` is passed as a plain `let` (low-churn) so the pane
            // observes ONLY liveText, not the VM.
            LivePaneView(liveText: vm.liveText, isRunning: vm.isRunning)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    @State private var copyConfirm: String? = nil

    private func columnHeader(title: String,
                              subtitle: String?,
                              accent: Color,
                              copyAction: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 3, height: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                if let sub = subtitle {
                    Text(sub).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary).tracking(0.5)
                }
            }
            Spacer()
            if let copyAction {
                let key = title
                Button(action: {
                    copyAction()
                    copyConfirm = key
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        if copyConfirm == key { copyConfirm = nil }
                    }
                }, label: {
                    HStack(spacing: 4) {
                        Image(systemName: copyConfirm == key ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                        Text(copyConfirm == key ? "Copied" : "Copy").font(.caption)
                    }
                    .foregroundStyle(copyConfirm == key ? Color.green : Color.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.08)))
                })
                .buttonStyle(.plain)
                .disabled(!vm.hasPairs)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Helpers

    private func copyAllEnglish() {
        let text = vm.transcript.pairs.map(\.english).joined(separator: "\n\n")
        copyToClipboard(text)
    }

    private func copyAllOther() {
        let text = vm.transcript.pairs.map(\.other).joined(separator: "\n\n")
        copyToClipboard(text)
    }

    private func copyToClipboard(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(trimmed, forType: .string)
    }
}

// MARK: - Live pane (isolated subview)

/// The current-utterance pane, extracted into its own `View` that observes ONLY the
/// high-churn `LiveTextStore` (passed as `LivePaneView(liveText: vm.liveText)`). A translation
/// delta fires objectWillChange on `liveText` only, so it re-renders ONLY this small pane —
/// the toolbar, column headers, history list, and status bar are untouched. `isRunning` is a
/// plain `let` (low-churn) so this pane does NOT observe the VM at all.
private struct LivePaneView: View {
    @ObservedObject var liveText: LiveTextStore
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 0) {
            liveCell(text: liveText.other, accent: .indigo)
            Divider()
            liveCell(text: liveText.english, accent: .blue)
        }
        .frame(height: 90)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
    }

    // No ScrollView here — a fixed-height caption box with the text bottom-aligned and
    // clipped keeps the latest words visible (like live captions) without paying for
    // ScrollView/ScrollViewReader layout + a scrollTo animation on every delta. That
    // ScrollView relayout-per-delta was the dominant remaining CPU cost during speech.
    private func liveCell(text: String, accent: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent.opacity(text.isEmpty ? 0.15 : 0.55))
                .frame(width: 3)
            cellContent(text: text, accent: accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private func cellContent(text: String, accent: Color) -> some View {
        if text.isEmpty {
            if isRunning {
                HStack(spacing: 6) {
                    Circle().fill(accent.opacity(0.6)).frame(width: 6, height: 6)
                    Text("Listening…").font(.system(size: 13)).italic().foregroundStyle(.tertiary)
                }
            } else {
                Text("Idle").font(.system(size: 13)).foregroundStyle(.tertiary)
            }
        } else {
            Text(text)
                .font(.system(size: 16))
                .lineSpacing(4)
                .italic()
                .foregroundStyle(.primary.opacity(0.9))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Status bar (isolated subview)

/// The bottom diagnostics/status bar. Observes the high-churn `DiagnosticsStore`
/// (`@ObservedObject var diagnostics`, passed as `StatusBarView(diagnostics: vm.diagnostics)`)
/// so the 4 Hz diagnostics tick fires objectWillChange on `diagnostics` only → re-renders
/// ONLY this bar, never ContentView.body. The low-churn status/permission values are read from
/// the VM via @EnvironmentObject (they change only on discrete control events, never at the
/// 4 Hz/delta rate, so observing the VM here does not reintroduce steady-state churn).
private struct StatusBarView: View {
    @ObservedObject var diagnostics: DiagnosticsStore
    @EnvironmentObject var vm: TranscriberViewModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                StatusBadge(text: vm.statusText, isRunning: vm.isRunning, isError: vm.statusIsError)
                Spacer()
                APIKeyChip(source: vm.apiKeySource, action: openSettingsWindow)
                PermissionChip(label: "Mic", state: vm.micPermission, relevant: vm.selectedSource.usesMic)
                PermissionChip(label: "Screen", state: vm.screenPermission, relevant: vm.selectedSource.usesScreen)
                Divider().frame(height: 14)
                DataChip(icon: "arrow.up.circle.fill",
                         text: formatBytes(diagnostics.audioBytesSent),
                         tint: (vm.isRunning && diagnostics.audioBytesSent == 0) ? .red : .secondary)
                Text(lastFrameText).font(.caption2.monospaced()).foregroundStyle(.secondary)
                Divider().frame(height: 14)
                Text("EN \(diagnostics.englishDeltasReceived) · \(vm.selectedOtherLanguage.uppercased()) \(diagnostics.otherDeltasReceived)")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                Divider().frame(height: 14)
                TranscriptionChip(status: diagnostics.transcriptionStatus,
                                  chars: diagnostics.transcriptionCharsReceived)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }

    private var lastFrameText: String {
        guard let last = diagnostics.lastAudioAt else { return "no audio" }
        let dt = Date().timeIntervalSince(last)
        if dt < 1.0 { return "live" }
        return String(format: "%.1fs", dt)
    }

    private func formatBytes(_ n: Int64) -> String {
        let kb = Double(n) / 1024
        if kb < 1 { return "\(n) B" }
        let mb = kb / 1024
        if mb < 1 { return String(format: "%.1f KB", kb) }
        return String(format: "%.2f MB", mb)
    }
}

// MARK: - Scroll position tracking

/// Reports the bottom sentinel's maxY (in the scroll viewport's coordinate space) so the
/// history view can decide whether it's parked at the bottom.
private struct HistoryBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - History list (isolated subview)

/// The finalized-utterance history list, extracted into its own `View` so it is diff-stable:
/// it observes NOTHING from the view model — its only inputs are the `pairs` array and the
/// `otherLanguage` code, passed as plain `let`s. When `ContentView.body` re-runs because of a
/// live-text or diagnostic change, SwiftUI compares this view's stored inputs, finds them
/// unchanged, and skips re-rendering the whole list — so scrolling is never interrupted by
/// live deltas. `UtterancePair` is `Equatable`, so the `Equatable` conformance gives SwiftUI a
/// cheap structural comparison (used via `.equatable()` at the call site / automatically).
///
/// Intentionally has NO auto-scroll except stick-to-bottom: the user can read past content
/// without being yanked down on every new pair. The live pane below shows the current
/// utterance, so the user never loses sight of what's currently being said.
/// Thin wrapper that observes ONLY the `TranscriptStore` (`@ObservedObject var transcript`,
/// passed as `HistoryContainerView(transcript: vm.transcript, ...)`) and feeds its `pairs`
/// into the equatable `HistoryListView`. This keeps the pairs dependency OUT of
/// `ContentView.body`: a pair flush fires objectWillChange on `transcript` only, re-rendering
/// just this container (which then lets the `.equatable()` list decide whether to redraw),
/// instead of re-running ContentView.body and rebuilding the toolbar's Pickers.
/// `otherLanguage` is a plain `let` (low-churn) passed down from ContentView.
private struct HistoryContainerView: View {
    @ObservedObject var transcript: TranscriptStore
    let otherLanguage: String
    var body: some View {
        HistoryListView(pairs: transcript.pairs, otherLanguage: otherLanguage)
            .equatable()
    }
}

private struct HistoryListView: View, Equatable {
    let pairs: [UtterancePair]
    let otherLanguage: String

    /// Whether the history scroll is parked at (or near) the bottom. Drives stick-to-bottom:
    /// new content auto-scrolls only while the user is already at the bottom. Local @State so
    /// scroll-position churn never touches the view model or ContentView.
    @State private var historyAtBottom = true

    private static let historyCoordSpace = "historyScroll"
    private static let historyBottomID = "history-bottom-anchor"

    // Equality is driven entirely by the inputs SwiftUI passes in. @State is excluded from
    // the synthesized/explicit comparison (it is owned by SwiftUI, not an input), so the list
    // re-renders only when pairs or the language actually change.
    //
    // `pairs` is append-only and each pair is immutable once committed (its id is a fixed
    // UUID), so count + last id uniquely identifies the list contents. This is O(1) instead
    // of the O(n) elementwise Array compare, which runs on every ContentView.body eval
    // (per delta + 4 Hz) and would otherwise grow with transcript length.
    static func == (lhs: HistoryListView, rhs: HistoryListView) -> Bool {
        lhs.otherLanguage == rhs.otherLanguage
            && lhs.pairs.count == rhs.pairs.count
            && lhs.pairs.last?.id == rhs.pairs.last?.id
    }

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    if pairs.isEmpty {
                        emptyState.padding(.top, 80).frame(maxWidth: .infinity)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(pairs) { pair in
                                pairRow(pair).id(pair.id)
                                Divider().opacity(0.4)
                            }
                            // Sentinel kept ONLY as a scrollTo target id. Its measurement
                            // used to drive "at bottom" detection, but that broke: when the
                            // user scrolls up the LazyVStack virtualizes the sentinel away,
                            // its GeometryReader stops publishing, and historyAtBottom froze
                            // at true. Detection now lives on the container background below.
                            Color.clear
                                .frame(height: 1)
                                .id(Self.historyBottomID)
                        }
                        // Measure the WHOLE content container, which is always laid out:
                        // a LazyVStack reports its full frame (full content height + current
                        // scroll offset) even while its child VIEWS are virtualized. In the
                        // viewport-anchored coordinate space its maxY shifts continuously as
                        // the user drags, so detection updates during the scroll.
                        .background(GeometryReader { g in
                            Color.clear.preference(
                                key: HistoryBottomKey.self,
                                value: g.frame(in: .named(Self.historyCoordSpace)).maxY)
                        })
                    }
                }
                .coordinateSpace(name: Self.historyCoordSpace)
                .onPreferenceChange(HistoryBottomKey.self) { contentMaxY in
                    // Content's bottom edge measured from the viewport top. At the bottom it
                    // sits at ≈ viewport height; scrolled up it exceeds viewport height. A
                    // small slack absorbs sub-pixel rounding and the animated settle.
                    historyAtBottom = contentMaxY <= outer.size.height + 24
                }
                .onChange(of: pairs.count) { _ in
                    guard historyAtBottom else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(Self.historyBottomID, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Rows

    private func pairRow(_ pair: UtterancePair) -> some View {
        HStack(alignment: .top, spacing: 0) {
            transcriptCell(pair.other, accent: .indigo,
                           isOriginal: pair.originalLanguage == .other)
            Divider()
            transcriptCell(pair.english, accent: .blue,
                           isOriginal: pair.originalLanguage == .english)
        }
        .contextMenu {
            Button("Copy English") { copyToClipboard(pair.english) }
            Button("Copy \(Languages.find(otherLanguage).displayName)") { copyToClipboard(pair.other) }
            Button("Copy Both") { copyToClipboard("\(pair.other)\n\n\(pair.english)") }
        }
    }

    private func transcriptCell(_ text: String, accent: Color, isOriginal: Bool = false) -> some View {
        Text(text.isEmpty ? "—" : text)
            .font(.system(size: 16))
            .lineSpacing(4)
            .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(isOriginal ? originalLanguageHighlight : Color.clear)
    }

    /// Soft green tint applied to the cell whose language the speaker actually used,
    /// as determined by Apple's NLLanguageRecognizer on the third (transcription-only)
    /// realtime session. Adapts naturally to dark mode via the system green.
    private var originalLanguageHighlight: Color {
        Color.green.opacity(0.14)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Ready")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Press \(Image(systemName: "play.circle.fill")) Start to begin. The current utterance shows in the pane below; finished paragraphs accumulate here for you to scroll through.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(.horizontal, 30)
    }

    private func copyToClipboard(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(trimmed, forType: .string)
    }
}

// MARK: - ConfigBanner

private struct ConfigBanner: View {
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "key.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 18))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text("OpenAI API key required")
                    .font(.system(size: 13, weight: .semibold))
                Text("Add your key in Settings — it'll be stored in the macOS Keychain. You can also drop it into config.json or set the OPENAI_API_KEY environment variable.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !message.isEmpty {
                    DisclosureGroup("Details") {
                        ScrollView {
                            Text(message)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 140)
                    }
                    .font(.caption)
                }
            }
            Spacer()
            Button {
                openSettingsWindow()
            } label: {
                Label("Open Settings", systemImage: "gearshape.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut(",", modifiers: .command)
        }
        .padding(14)
        .background(Color.orange.opacity(0.10))
        .overlay(Divider(), alignment: .bottom)
    }
}

// MARK: - APIKeyChip

private struct APIKeyChip: View {
    let source: AppConfig.APIKeySource
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).foregroundStyle(color).font(.system(size: 11))
                Text(text).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    private var configured: Bool { source != .none }
    private var symbol: String { configured ? "key.fill" : "key.slash" }
    private var color: Color { configured ? .green : .red }
    private var text: String {
        switch source {
        case .keychain:   return "Key · Keychain"
        case .configFile: return "Key · config.json"
        case .envVar:     return "Key · env"
        case .none:       return "No API key"
        }
    }
    private var tooltip: String {
        switch source {
        case .keychain:   return "API key loaded from the macOS Keychain. Click to manage in Settings."
        case .configFile: return "API key loaded from config.json. Click to manage in Settings (Keychain is preferred)."
        case .envVar:     return "API key loaded from the OPENAI_API_KEY environment variable. Click to manage in Settings."
        case .none:       return "No API key set — click to open Settings."
        }
    }
}

// MARK: - StatusBadge / PermissionChip / DataChip

private struct StatusBadge: View {
    let text: String
    let isRunning: Bool
    let isError: Bool

    var body: some View {
        HStack(spacing: 6) {
            // Static indicator: a filled dot, with a thin static ring while running. No
            // continuous animation — a repeatForever pulse drove the render loop every
            // display frame even in silence, which was a major source of idle CPU.
            ZStack {
                if isRunning && !isError {
                    Circle().stroke(color.opacity(0.4), lineWidth: 2).frame(width: 13, height: 13)
                }
                Circle().fill(color).frame(width: 8, height: 8)
            }
            .frame(width: 14, height: 14)
            Text(text).font(.caption).foregroundStyle(isError ? Color.red : Color.secondary)
        }
    }

    private var color: Color {
        if isError { return .red }
        if isRunning { return .green }
        return .gray
    }
}

private struct PermissionChip: View {
    let label: String
    let state: PermissionState
    let relevant: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(symbolColor).font(.system(size: 11))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(symbolColor.opacity(0.10)))
        .opacity(relevant ? 1 : 0.4)
        .help(relevant ? "\(label) permission: \(state.label)" : "\(label) not needed for this source")
    }

    private var symbol: String {
        if !relevant { return "minus.circle" }
        switch state {
        case .granted:      return "checkmark.circle.fill"
        case .denied:       return "xmark.circle.fill"
        case .undetermined: return "questionmark.circle.fill"
        }
    }
    private var symbolColor: Color {
        if !relevant { return .secondary }
        switch state {
        case .granted:      return .green
        case .denied:       return .red
        case .undetermined: return .orange
        }
    }
}

private extension PermissionState {
    var label: String {
        switch self {
        case .granted: return "granted"
        case .denied: return "denied — System Settings → Privacy & Security, then relaunch"
        case .undetermined: return "not yet determined"
        }
    }
}

private struct DataChip: View {
    let icon: String
    let text: String
    let tint: Color
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).foregroundStyle(tint).font(.system(size: 11))
            Text(text).font(.caption2.monospaced()).foregroundStyle(.secondary)
        }
    }
}

/// Chip for the source-language transcription session (used to drive the green "original
/// language" highlight). Green when connected and receiving text, orange when connecting,
/// red on failure, gray when off.
private struct TranscriptionChip: View {
    let status: String
    let chars: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.system(size: 11))
            Text("LID \(chars)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.10)))
        .help("Source-language transcription session — \(status). Drives the green highlight on the originally-spoken cell. \(chars) chars received.")
    }

    private var tint: Color {
        if status.hasPrefix("failed") { return .red }
        switch status {
        case "connected":  return chars > 0 ? .green : .orange
        case "connecting": return .orange
        case "off":        return .gray
        default:           return .secondary
        }
    }

    private var symbol: String {
        if status.hasPrefix("failed") { return "exclamationmark.triangle.fill" }
        switch status {
        case "connected":  return chars > 0 ? "checkmark.circle.fill" : "ellipsis.circle.fill"
        case "connecting": return "ellipsis.circle.fill"
        case "off":        return "minus.circle"
        default:           return "questionmark.circle"
        }
    }
}

// MARK: - Open Settings helper

private func openSettingsWindow() {
    NSApp.activate(ignoringOtherApps: true)
    if let appMenu = NSApp.mainMenu?.items.first?.submenu {
        for (idx, item) in appMenu.items.enumerated() {
            let title = item.title.lowercased()
            if title.contains("setting") || title.contains("preferenc") {
                appMenu.performActionForItem(at: idx)
                return
            }
        }
    }
    if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) { return }
    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
}
