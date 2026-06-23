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
            statusBar
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
            .disabled(vm.pairs.isEmpty && !hasAnyLive)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(Divider(), alignment: .bottom)
    }

    private var hasAnyLive: Bool {
        !vm.liveEnglish.isEmpty || !vm.liveOther.isEmpty
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
            // No auto-scroll: scroll position is stable while you read.
            historyScroll
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Live pane (fixed) + breathing room before the status bar. The padding lives
            // on the live pane itself so the surrounding view doesn't grow.
            livePane
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
                .disabled(vm.pairs.isEmpty)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
    }

    // History scroll view — intentionally has NO auto-scroll. The user can read past
    // content without being pulled to the bottom every time a new pair lands. The live
    // pane below shows the current utterance, so the user never loses sight of what's
    // currently being said.
    private var historyScroll: some View {
        ScrollView {
            if vm.pairs.isEmpty {
                emptyState.padding(.top, 80).frame(maxWidth: .infinity)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(vm.pairs) { pair in
                        pairRow(pair).id(pair.id)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }

    // MARK: - Rows

    private func pairRow(_ pair: UtterancePair) -> some View {
        HStack(alignment: .top, spacing: 0) {
            transcriptCell(pair.other, accent: .indigo)
            Divider()
            transcriptCell(pair.english, accent: .blue)
        }
        .contextMenu {
            Button("Copy English") { copyToClipboard(pair.english) }
            Button("Copy \(Languages.find(vm.selectedOtherLanguage).displayName)") { copyToClipboard(pair.other) }
            Button("Copy Both") { copyToClipboard("\(pair.other)\n\n\(pair.english)") }
        }
    }

    private func transcriptCell(_ text: String, accent: Color) -> some View {
        Text(text.isEmpty ? "—" : text)
            .font(.system(size: 16))
            .lineSpacing(4)
            .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
    }

    // MARK: - Live pane (the current utterance, separated from history)

    private var livePane: some View {
        HStack(spacing: 0) {
            liveCell(text: vm.liveOther, accent: .indigo)
            Divider()
            liveCell(text: vm.liveEnglish, accent: .blue)
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

    private func liveCell(text: String, accent: Color) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(accent.opacity(text.isEmpty ? 0.15 : 0.55))
                        .frame(width: 3)
                    Group {
                        if text.isEmpty {
                            if vm.isRunning {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(accent.opacity(0.6))
                                        .frame(width: 6, height: 6)
                                    Text("Listening…")
                                        .font(.system(size: 13))
                                        .italic()
                                        .foregroundStyle(.tertiary)
                                }
                            } else {
                                Text("Idle")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.tertiary)
                            }
                        } else {
                            Text(text)
                                .font(.system(size: 16))
                                .lineSpacing(4)
                                .italic()
                                .foregroundStyle(.primary.opacity(0.9))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("end")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
            }
            .onChange(of: text) { _ in
                if !text.isEmpty {
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }
        }
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

    // MARK: - Status bar

    private var statusBar: some View {
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
                         text: formatBytes(vm.audioBytesSent),
                         tint: (vm.isRunning && vm.audioBytesSent == 0) ? .red : .secondary)
                Text(lastFrameText).font(.caption2.monospaced()).foregroundStyle(.secondary)
                Divider().frame(height: 14)
                Text("EN \(vm.englishDeltasReceived) · \(vm.selectedOtherLanguage.uppercased()) \(vm.otherDeltasReceived)")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.regularMaterial)
        }
    }

    // MARK: - Helpers

    private var lastFrameText: String {
        guard let last = vm.lastAudioAt else { return "no audio" }
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

    private func copyAllEnglish() {
        let text = vm.pairs.map(\.english).joined(separator: "\n\n")
        copyToClipboard(text)
    }

    private func copyAllOther() {
        let text = vm.pairs.map(\.other).joined(separator: "\n\n")
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

// MARK: - StatusBadge / PulsingRing / PermissionChip / DataChip

private struct StatusBadge: View {
    let text: String
    let isRunning: Bool
    let isError: Bool

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(color).frame(width: 8, height: 8)
                if isRunning && !isError { PulsingRing(color: color) }
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

private struct PulsingRing: View {
    let color: Color
    @State private var animate = false
    var body: some View {
        Circle()
            .stroke(color.opacity(animate ? 0 : 0.55), lineWidth: 2)
            .frame(width: animate ? 14 : 8, height: animate ? 14 : 8)
            .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: animate)
            .onAppear { animate = true }
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
