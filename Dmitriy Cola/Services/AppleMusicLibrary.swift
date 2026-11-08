import SwiftUI
import Speech
import AVFoundation
import UserNotifications
import AppKit
import Combine

struct PlayerSnapshot {
    let track: Track?
    let artwork: NSImage?
}

final class AppleMusicLibrary {
    private let queue = DispatchQueue(label: "VoiceMusic.AppleMusic")
    private var cachedUserTracks: [Track] = []
    private var cachedArtworkTrackID: String?
    private var cachedArtwork: NSImage?

    func contextualTrackNames() -> [String] {
        let all = loadUserPlaylistTracks()
        cachedUserTracks = all
        return Array(Set(all.map(\.title))).prefix(90).map { $0 }
    }

    func findAndPlay(candidates: [String], completion: @escaping ((track: Track, artwork: NSImage?)?, String?) -> Void) {
        queue.async {
            let tracks = self.cachedUserTracks.isEmpty ? self.loadUserPlaylistTracks() : self.cachedUserTracks
            guard !tracks.isEmpty else {
                DispatchQueue.main.async { completion(nil, "Не удалось прочитать пользовательские плейлисты Apple Music") }
                return
            }
            guard let best = self.bestMatch(candidates: candidates, tracks: tracks) else {
                DispatchQueue.main.async {
                    let isRussian = Locale.current.language.languageCode?.identifier == "ru"
                    let message = isRussian
                        ? "В пользовательских плейлистах не найден достаточно похожий трек"
                        : "No close match was found in your playlists"
                    completion(nil, message)
                }
                return
            }
            let artwork = self.artwork(for: best)
            let playlistName = Self.escapeAppleScript(best.playlist)
            let playScript = """
            tell application "Music"
                set targetID to \(best.databaseID) as integer
                repeat with p in user playlists
                    if (name of p as text) is "\(playlistName)" then
                        repeat with t in tracks of p
                            if (database ID of t) is targetID then
                                play t
                                return name of t as text
                            end if
                        end repeat
                    end if
                end repeat
                error "Track disappeared from playlist"
            end tell
            """
            guard Self.runAppleScript(playScript) != nil else {
                DispatchQueue.main.async {
                    let isRussian = Locale.current.language.languageCode?.identifier == "ru"
                    let message = isRussian
                        ? "Нашёл «\(best.title)», но Music не смог включить трек"
                        : "Found “\(best.title)”, but Music could not start playback"
                    completion(nil, message)
                }
                return
            }
            DispatchQueue.main.async { completion((best, artwork), nil) }
        }
    }

    func pausePlayback(completion: @escaping (String?) -> Void) {
        queue.async {
            let script = #"""
            tell application "Music" to pause
            return "PAUSED"
            """#
            let result = Self.runAppleScript(script)
            DispatchQueue.main.async {
                completion(result == nil ? "Не удалось поставить Apple Music на паузу" : nil)
            }
        }
    }

    func performTrackAction(_ action: String, completion: @escaping (String?) -> Void) {
        queue.async {
            let script: String
            switch action {
            case "previous":
                script = #"""
                tell application "Music"
                    if not (exists current track) then error "No current track"
                    set player position to 0
                    previous track
                    return "PREVIOUS"
                end tell
                """#
            case "next":
                script = #"""
                tell application "Music"
                    if not (exists current track) then error "No current track"
                    next track
                    return "NEXT"
                end tell
                """#
            case "restart":
                script = #"""
                tell application "Music"
                    if not (exists current track) then error "No current track"
                    set player position to 0
                    play
                    return "RESTARTED"
                end tell
                """#
            default:
                DispatchQueue.main.async { completion("Неизвестная команда управления треком") }
                return
            }
            let result = Self.runAppleScript(script)
            DispatchQueue.main.async {
                completion(result == nil ? "Apple Music не смог выполнить команду управления треком" : nil)
            }
        }
    }

    func resumePlayback(completion: @escaping (String?) -> Void) {
        queue.async {
            let script = #"""
            tell application "Music" to play
            return "PLAYING"
            """#
            let result = Self.runAppleScript(script)
            DispatchQueue.main.async {
                completion(result == nil ? "Не удалось продолжить воспроизведение в Apple Music" : nil)
            }
        }
    }

    func findAndPlayPlaylist(candidates: [String], completion: @escaping (String?, String?) -> Void) {
        queue.async {
            let script = #"""
            tell application "Music"
                set outputText to ""
                repeat with p in user playlists
                    set outputText to outputText & (name of p as text) & linefeed
                end repeat
                return outputText
            end tell
            """#
            guard let output = Self.runAppleScript(script) else {
                DispatchQueue.main.async { completion(nil, "Не удалось прочитать пользовательские плейлисты Apple Music") }
                return
            }
            let playlists = output.split(whereSeparator: \.isNewline).map(String.init)
            let queries = candidates.map(Self.normalize).filter { !$0.isEmpty }
            guard !playlists.isEmpty, !queries.isEmpty else {
                DispatchQueue.main.async { completion(nil, "Пользовательские плейлисты не найдены") }
                return
            }
            let ranked = playlists.map { name -> (String, Double) in
                let normalizedName = Self.normalize(name)
                let score = queries.map { query in
                    max(Self.similarity(query, normalizedName),
                        Self.tokenSimilarity(query, normalizedName),
                        Self.wordSimilarity(query, normalizedName),
                        Self.phoneticSimilarity(query, normalizedName))
                }.max() ?? 0
                return (name, score)
            }.sorted { $0.1 > $1.1 }
            guard let best = ranked.first, best.1 >= 0.56 else {
                DispatchQueue.main.async { completion(nil, "Не найден похожий пользовательский плейлист") }
                return
            }
            if ranked.count > 1, best.1 - ranked[1].1 < 0.012, best.1 < 0.9,
               best.0 != ranked[1].0 {
                DispatchQueue.main.async { completion(nil, "Название плейлиста неоднозначно") }
                return
            }
            let escapedName = Self.escapeAppleScript(best.0)
            let playScript = """
            tell application "Music"
                repeat with p in user playlists
                    if (name of p as text) is "\(escapedName)" then
                        play p
                        return name of p as text
                    end if
                end repeat
                error "Playlist disappeared"
            end tell
            """
            guard Self.runAppleScript(playScript) != nil else {
                DispatchQueue.main.async { completion(nil, "Нашёл плейлист «\(best.0)», но Music не смог его включить") }
                return
            }
            DispatchQueue.main.async { completion(best.0, nil) }
        }
    }

    func duck(to volume: Int, completion: @escaping (Int?) -> Void) {
        queue.async {
            let old = Self.runAppleScript(#"tell application "Music" to get sound volume"#)
                .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            _ = Self.runAppleScript(#"tell application "Music" to set sound volume to \#(max(1, min(100, volume)))"#)
            DispatchQueue.main.async { completion(old) }
        }
    }

    func setVolume(_ volume: Int) {
        let safeVolume = max(1, min(100, volume))
        queue.async { _ = Self.runAppleScript("tell application \"Music\" to set sound volume to \(safeVolume)") }
    }

    func fetchNowPlaying(completion: @escaping (Track?, NSImage?) -> Void) {
        queue.async {
            let script = #"""
            tell application "Music"
                if not (exists current track) then return ""
                set t to current track
                return (name of t as text) & tab & (artist of t as text) & tab & (database ID of t as text)
            end tell
            """#
            guard let output = Self.runAppleScript(script) else {
                DispatchQueue.main.async { completion(nil, nil) }
                return
            }
            let fields = output.components(separatedBy: "\t")
            guard fields.count >= 3 else {
                DispatchQueue.main.async { completion(nil, nil) }
                return
            }
            let track = Track(title: fields[0], artist: fields[1], playlist: "", databaseID: fields[2])
            let artwork: NSImage?
            if self.cachedArtworkTrackID == track.databaseID {
                artwork = self.cachedArtwork
            } else {
                artwork = self.artwork(for: track)
                self.cachedArtworkTrackID = track.databaseID
                self.cachedArtwork = artwork
            }
            DispatchQueue.main.async { completion(track, artwork) }
        }
    }

    private func artwork(for track: Track) -> NSImage? {
        let script: String
        if track.playlist.isEmpty {
            script = """
            tell application "Music"
                repeat with p in user playlists
                    repeat with t in tracks of p
                        if (database ID of t) is (\(track.databaseID) as integer) then
                            if (count of artworks of t) is 0 then return ""
                            return raw data of artwork 1 of t
                        end if
                    end repeat
                end repeat
                return ""
            end tell
            """
        } else {
            let escapedPlaylist = Self.escapeAppleScript(track.playlist)
            script = """
            tell application "Music"
                repeat with p in user playlists
                    if (name of p as text) is "\(escapedPlaylist)" then
                        repeat with t in tracks of p
                            if (database ID of t) is (\(track.databaseID) as integer) then
                                if (count of artworks of t) is 0 then return ""
                                return raw data of artwork 1 of t
                            end if
                        end repeat
                    end if
                end repeat
                return ""
            end tell
            """
        }
        guard let scriptObject = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let result = scriptObject.executeAndReturnError(&error)
        guard error == nil else { return nil }
        let data = result.data
        guard !data.isEmpty else { return nil }
        return NSImage(data: data)
    }

    private func loadUserPlaylistTracks() -> [Track] {
        let source = #"""
        tell application "Music"
            set outputText to ""
            repeat with p in user playlists
                set playlistName to name of p as text
                repeat with t in tracks of p
                    set outputText to outputText & (name of t as text) & tab & (artist of t as text) & tab & playlistName & tab & (database ID of t as text) & linefeed
                end repeat
            end repeat
            return outputText
        end tell
        """#
        guard let output = Self.runAppleScript(source) else { return [] }
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4 else { return nil }
            return Track(title: fields[0], artist: fields[1], playlist: fields[2], databaseID: fields[3])
        }
    }

    private func bestMatch(candidates: [String], tracks: [Track]) -> Track? {
        let queries = candidates.map { Self.normalize($0) }.filter { !$0.isEmpty }
        guard !queries.isEmpty else { return nil }
        let ranked = tracks.map { track -> (Track, Double) in
            let title = Self.normalize(track.title)
            let artist = Self.normalize(track.artist)
            let full = title + " " + artist
            let queryScore = queries.map { query in
                let queryTokens = query.split(separator: " ").map(String.init)
                let titleTokens = title.split(separator: " ").map(String.init)
                let prefix: Double
                if queryTokens.count == 1, let token = queryTokens.first,
                   titleTokens.contains(where: { $0 == token || $0.hasPrefix(token) }) {
                    prefix = token.count < 4 ? 0.80 : 0.93
                } else { prefix = 0 }
                return max(prefix, Self.similarity(query, title), Self.similarity(query, full) * 0.96,
                           Self.tokenSimilarity(query, title), Self.tokenSimilarity(query, full) * 0.94,
                           Self.wordSimilarity(query, title), Self.wordSimilarity(query, full) * 0.94,
                           Self.phoneticSimilarity(query, title), Self.phoneticSimilarity(query, full) * 0.94)
            }.max() ?? 0
            return (track, queryScore)
        }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first, best.1 >= 0.56 else { return nil }
        if ranked.count > 1, best.1 - ranked[1].1 < 0.012, best.1 < 0.9,
           best.0.title != ranked[1].0.title {
            return nil
        }
        return best.0
    }

    private static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let latin = folded.applyingTransform(.toLatin, reverse: false) ?? folded
        return latin.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    private static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var row = Array(0...b.count)
        for (i, ca) in Array(a).enumerated() {
            var next = [i + 1]
            for (j, cb) in Array(b).enumerated() {
                next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (ca == cb ? 0 : 1)))
            }
            row = next
        }
        return 1 - Double(row[b.count]) / Double(max(a.count, b.count))
    }

    private static func wordSimilarity(_ a: String, _ b: String) -> Double {
        let queryWords = a.split(separator: " ").map(String.init)
        let targetWords = b.split(separator: " ").map(String.init)
        guard !queryWords.isEmpty, !targetWords.isEmpty else { return 0 }
        let bestScores = queryWords.map { queryWord in
            targetWords.map { targetWord in
                max(similarity(queryWord, targetWord), phoneticSimilarity(queryWord, targetWord))
            }.max() ?? 0
        }
        let matched = bestScores.filter { $0 >= 0.45 }.count
        let coverage = Double(matched) / Double(queryWords.count)
        let average = bestScores.reduce(0, +) / Double(bestScores.count)
        return average * (0.65 + 0.35 * coverage)
    }

    private static func tokenSimilarity(_ a: String, _ b: String) -> Double {
        let x = Set(a.split(separator: " ").map(String.init))
        let y = Set(b.split(separator: " ").map(String.init))
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    private static func phoneticSimilarity(_ a: String, _ b: String) -> Double {
        let aWords = a.split(separator: " ").map(String.init)
        let bWords = b.split(separator: " ").map(String.init)
        guard !aWords.isEmpty, !bWords.isEmpty else { return 0 }
        return aWords.map { word in bWords.map { trigramDice(word, $0) }.max() ?? 0 }.reduce(0, +) / Double(aWords.count)
    }

    private static func trigramDice(_ a: String, _ b: String) -> Double {
        func grams(_ value: String) -> Set<String> {
            let chars = Array("  \(value)  ")
            guard chars.count >= 3 else { return [value] }
            return Set((0...(chars.count - 3)).map { String(chars[$0...($0 + 2)]) })
        }
        let x = grams(a), y = grams(b)
        guard x.count + y.count > 0 else { return 0 }
        return 2 * Double(x.intersection(y).count) / Double(x.count + y.count)
    }

    private static func escapeAppleScript(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runAppleScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error { NSLog("VoiceMusic AppleScript error: %@", error) }
        return error == nil ? result.stringValue : nil
    }
}
