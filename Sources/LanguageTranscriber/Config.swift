import Foundation

struct AppConfig: Codable {
    let apiKey: String
    var model: String?              // realtime translation model. Default: "gpt-realtime-translate"
    var otherLanguage: String?      // ISO 639-1 code for the non-English pane. If nil, auto-detect.
    var segmentSilenceMs: Int?      // ms of no deltas before pushing a segment to history. Default: 1500.

    /// Where the API key actually came from for this load.
    enum APIKeySource: String {
        case keychain
        case configFile
        case envVar
        case none

        var displayName: String {
            switch self {
            case .keychain:   return "Keychain"
            case .configFile: return "config.json"
            case .envVar:     return "OPENAI_API_KEY env var"
            case .none:       return "not set"
            }
        }
    }

    /// Result of attempting to load a config: either a parsed config or the list of paths searched
    /// (for surfacing in the UI if nothing was found).
    enum LoadResult {
        case loaded(AppConfig, source: APIKeySource)
        case notFound(searched: [String], parseErrors: [(path: String, error: String)])
    }

    static func load() -> LoadResult {
        var searched: [String] = []
        var parseErrors: [(String, String)] = []

        // The Keychain is the preferred place to keep the API key. We still load other
        // settings (model, otherLanguage, segmentSilenceMs) from config.json if present.
        let keychainKey = KeychainStore.loadAPIKey()

        let decoder = JSONDecoder()

        var loadedFromJSON: AppConfig?
        for url in candidatePaths() {
            searched.append(url.path)
            // We can decode without a config.json present — only its non-key settings matter
            // once a Keychain key exists.
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let data = try Data(contentsOf: url)
                loadedFromJSON = try decoder.decode(AppConfig.self, from: data)
                break
            } catch {
                // Tolerate a JSON file with no apiKey if we have a Keychain key:
                // decode just the optional fields.
                if let k = keychainKey, !k.isEmpty,
                   let partial = try? decoder.decode(PartialConfig.self, from: (try? Data(contentsOf: url)) ?? Data()) {
                    loadedFromJSON = AppConfig(
                        apiKey: k,
                        model: partial.model,
                        otherLanguage: partial.otherLanguage,
                        segmentSilenceMs: partial.segmentSilenceMs
                    )
                    break
                }
                parseErrors.append((url.path, "\(error)"))
            }
        }

        // 1) Both Keychain key and JSON present → Keychain key wins, other JSON fields kept.
        if let k = keychainKey, !k.isEmpty, let json = loadedFromJSON {
            return .loaded(AppConfig(
                apiKey: k,
                model: json.model,
                otherLanguage: json.otherLanguage,
                segmentSilenceMs: json.segmentSilenceMs
            ), source: .keychain)
        }

        // 2) Only JSON present → use it as-is.
        if let json = loadedFromJSON {
            return .loaded(json, source: .configFile)
        }

        // 3) Only Keychain key present → defaults for everything else.
        if let k = keychainKey, !k.isEmpty {
            return .loaded(
                AppConfig(apiKey: k, model: nil, otherLanguage: nil, segmentSilenceMs: nil),
                source: .keychain
            )
        }

        // 4) Env-var fallback.
        if let envKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !envKey.isEmpty {
            return .loaded(
                AppConfig(apiKey: envKey, model: nil, otherLanguage: nil, segmentSilenceMs: nil),
                source: .envVar
            )
        }

        return .notFound(searched: searched, parseErrors: parseErrors)
    }

    /// Same as AppConfig but apiKey is optional — used to parse config.json when the key
    /// itself comes from the Keychain.
    private struct PartialConfig: Codable {
        var apiKey: String?
        var model: String?
        var otherLanguage: String?
        var segmentSilenceMs: Int?
    }

    /// Build the ordered list of locations to check, robust to whether `Bundle.main` resolves to
    /// the `.app` or to the executable's directory.
    private static func candidatePaths() -> [URL] {
        var paths: [URL] = []

        // 1. Current working directory (mostly useful when running from terminal, not via `open`).
        paths.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("config.json"))

        // 2-N. Walk up from the executable, up to 6 levels, checking each directory.
        //      For a build at `<root>/build/LanguageTranscriber.app/Contents/MacOS/exe` this checks:
        //        Contents/MacOS, Contents, LanguageTranscriber.app, build, <root>, <root>'s parent.
        if let exe = Bundle.main.executableURL {
            var dir = exe.deletingLastPathComponent()
            for _ in 0..<6 {
                paths.append(dir.appendingPathComponent("config.json"))
                let parent = dir.deletingLastPathComponent()
                if parent == dir { break }   // reached filesystem root
                dir = parent
            }
        }

        // Bundle-based path as an additional best-effort.
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
        paths.append(bundleParent.appendingPathComponent("config.json"))

        // Standard user-config locations.
        let home = FileManager.default.homeDirectoryForCurrentUser
        paths.append(home.appendingPathComponent(".config/language-transcriber/config.json"))
        paths.append(home.appendingPathComponent(".language-transcriber.json"))

        // De-duplicate while preserving order.
        var seen = Set<String>()
        return paths.filter { seen.insert($0.path).inserted }
    }

    var resolvedModel: String { model ?? "gpt-realtime-translate" }
    var resolvedSegmentSilenceMs: Int { segmentSilenceMs ?? 1500 }
}
