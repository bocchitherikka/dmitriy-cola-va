import SwiftUI
import Speech
import AVFoundation
import UserNotifications
import AppKit
import Combine

@MainActor
final class VoiceController: ObservableObject {
    @Published var isListening = false
    @Published var status = "Остановлено"
    @Published var lastHeard = ""
    @Published var liveTranscript = ""
    @Published var currentTrack: Track?
    @Published var currentArtwork: NSImage?
    @Published var duckVolume: Double = 8
    @Published var waitingForWakeWord = true
    @Published var waitingForPlayCommand = false

    private let audioEngine = AVAudioEngine()
    private let audioLock = NSLock()
    private var requests: [String: SFSpeechAudioBufferRecognitionRequest] = [:]
    private var tasks: [String: SFSpeechRecognitionTask] = [:]
    private var taskIDs: [String: UUID] = [:]
    private var latest: [String: (String, Float)] = [:]
    private var alternatives: [String: [(String, Float)]] = [:]
    private var triggerCounts: [String: Int] = [:]
    private var wakeCounts: [String: Int] = [:]
    private var wakeBaselines: [String: Int] = [:]
    private var triggerBaselines: [String: Int] = [:]
    private var pendingCandidates: [String: (query: String, confidence: Float)] = [:]
    private var wakeTimeoutWork: DispatchWorkItem?
    private var handledCommands = Set<String>()
    private var failedLocales = Set<String>()
    private var debounce: DispatchWorkItem?
    private var nowPlayingTimer: Timer?
    private var duckWork: DispatchWorkItem?
    private var isStarting = false
    private var tapInstalled = false
    private var sessionID = UUID()
    private var lastDuckDate = Date.distantPast
    private var originalMusicVolume: Int?
    private var volumeRestoreRequested = false
    private var volumeDuckPending = false
    private var lastWakeDetected = Date.distantPast
    private var wakeEpoch = 0
    private var launchedMusicForSession = false
    private let musicWasOpenAtAppLaunch = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    private var playlistContext: [String] = []
    private let appleMusic = AppleMusicLibrary()
    private let locales = ["en-US", "ru-RU"]

    var isBusy: Bool { isStarting }

    private static let wakeWords = ["дмитрий", "дмитри", "дима", "димон", "димка", "димыч", "димас", "дмитро", "димася"]
    private static let playWords = ["включи", "вруби", "поставь", "запусти", "играй", "включить", "стоп", "пауза", "паузу", "приостанови", "останови", "выключи", "pause", "stop", "play", "плейлист", "playlist"]
    private static let pauseCommandMarker = "\u{1F}PAUSE"
    private static let resumeCommandMarker = "\u{1F}RESUME"
    private static let previousCommandMarker = "\u{1F}PREVIOUS"
    private static let nextCommandMarker = "\u{1F}NEXT"
    private static let restartCommandMarker = "\u{1F}RESTART"
    private static let commandPattern = #"(?i)включи\s+(?:трек\s+)?(?:ещё\s+раз|еще\s+раз)|начни\s+сначала|с\s+самого\s+начала|по\s+новой|заново|сначала|restart(?:\s+track)?|previous\s+track|next\s+track|следующий(?:\s+трек)?|следующую(?:\s+песню)?|предыдущий(?:\s+трек)?|предыдущую(?:\s+песню)?|прошлый\s+трек|прошлую\s+песню|назад|дальше|\b(?:next|skip)\b|продолжай(?:те)?(?:\s+(?:музыку|воспроизведение))?|продолжи(?:ть)?(?:\s+(?:музыку|воспроизведение))?|возобнови(?:ть)?(?:\s+(?:музыку|воспроизведение))?|играй\s+дальше|resume(?:\s+playback)?|continue(?:\s+playing)?|поставь\s+(?:(?:музыку|воспроизведение)\s+)?(?:на\s+)?паузу|приостанови(?:ть)?(?:\s+(?:музыку|воспроизведение))?|останови(?:сь|ть)?(?:\s+(?:музыку|воспроизведение))?|выключи\s+(?:музыку|воспроизведение)|стоп|пауза|паузу|включи|вруби|включить|поставь|запусти|играй|\b(?:pause|stop|play)\b"#
    private static let playlistPattern = #"(?i)\bплейлист(?:а|у|ом|е|ы|ов|ам|ами)?\b|\bplaylists?\b"#

    func start() {
        guard !isListening, !isStarting else { return }
        isStarting = true
        status = "Запрашиваю доступ к речи и микрофону…"
        SFSpeechRecognizer.requestAuthorization { [weak self] authorization in
            guard let self else { return }
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                Task { @MainActor in
                    guard self.isStarting else { return }
                    guard authorization == .authorized, allowed else {
                        self.isStarting = false
                        self.status = "Нужен доступ к распознаванию речи и микрофону в настройках macOS"
                        return
                    }
                    self.beginListening()
                }
            }
        }
    }

    func stop() {
        isStarting = false
        isListening = false
        sessionID = UUID()
        debounce?.cancel()
        debounce = nil
        duckWork?.cancel()
        nowPlayingTimer?.invalidate()
        nowPlayingTimer = nil
        audioEngine.stop()
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        audioLock.lock()
        let oldTasks = Array(tasks.values)
        tasks.removeAll()
        taskIDs.removeAll()
        requests.removeAll()
        audioLock.unlock()
        oldTasks.forEach { $0.cancel() }
        latest.removeAll()
        alternatives.removeAll()
        triggerCounts.removeAll()
        wakeCounts.removeAll()
        pendingCandidates.removeAll()
        wakeBaselines.removeAll()
        triggerBaselines.removeAll()
        wakeTimeoutWork?.cancel()
        wakeTimeoutWork = nil
        handledCommands.removeAll()
        waitingForWakeWord = true
        waitingForPlayCommand = false
        failedLocales.removeAll()
        lastHeard = ""
        liveTranscript = ""
        status = "Остановлено"
        restoreMusicVolume()
    }

    private func beginListening() {
        guard !isListening else { return }
        audioEngine.stop()
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        sessionID = UUID()
        let session = sessionID
        requests.removeAll()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        taskIDs.removeAll()
        latest.removeAll()
        alternatives.removeAll()
        triggerCounts.removeAll()
        wakeCounts.removeAll()
        pendingCandidates.removeAll()
        wakeBaselines.removeAll()
        wakeTimeoutWork?.cancel()
        wakeTimeoutWork = nil
        handledCommands.removeAll()
        waitingForWakeWord = true
        waitingForPlayCommand = false
        failedLocales.removeAll()
        lastHeard = ""
        liveTranscript = ""
        let musicWasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
        launchedMusicForSession = !musicWasOpenAtAppLaunch && !musicWasRunning
        playlistContext = appleMusic.contextualTrackNames()
        if launchedMusicForSession {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first?.hide()
            }
        }

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            isStarting = false
            status = "Не удалось открыть микрофон"
            return
        }

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.audioLock.lock()
            let activeRequests = Array(self.requests.values)
            self.audioLock.unlock()
            activeRequests.forEach { $0.append(buffer) }
        }
        tapInstalled = true
        do {
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            isStarting = false
            for locale in locales { startRecognizer(locale: locale, session: session) }
            if tasks.isEmpty {
                stop()
                status = "Ни одна модель распознавания не запустилась; проверь доступ к речи в macOS"
                return
            }
            status = "Жду русское обращение: Дмитрий / Дима"
            startNowPlayingPolling()
        } catch {
            let message = error.localizedDescription
            stop()
            status = "Не удалось запустить микрофон: \(message)"
        }
    }

    private func startRecognizer(locale: String, session: UUID) {
        guard isListening, sessionID == session else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
            failedLocales.insert(locale)
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .search
        let triggers = Self.wakeWords + Self.playWords
        request.contextualStrings = Array((triggers + playlistContext).prefix(100))
        if #available(macOS 13.0, *) { request.addsPunctuation = false }

        audioLock.lock()
        let previousRequest = requests.updateValue(request, forKey: locale)
        audioLock.unlock()
        let taskID = UUID()
        taskIDs[locale] = taskID
        let previousTask = tasks.removeValue(forKey: locale)
        previousRequest?.endAudio()
        latest.removeValue(forKey: locale)
        alternatives.removeValue(forKey: locale)
        triggerCounts[locale] = 0
        wakeCounts[locale] = 0
        wakeBaselines[locale] = 0
        triggerBaselines[locale] = 0
        let recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result {
                let isFinal = result.isFinal
                let hypotheses = result.transcriptions.map { transcription -> (String, Float) in
                    let score = transcription.segments.map(\.confidence).reduce(0, +)
                        / Float(max(transcription.segments.count, 1))
                    return (transcription.formattedString, score)
                }
                let transcript = result.bestTranscription.formattedString
                let confidence = result.bestTranscription.segments.map(\.confidence).reduce(0, +)
                    / Float(max(result.bestTranscription.segments.count, 1))
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isListening, self.sessionID == session,
                          self.taskIDs[locale] == taskID else { return }
                    self.latest[locale] = (transcript, confidence)
                    self.liveTranscript = transcript
                    self.alternatives[locale] = hypotheses
                    self.handleTranscriptUpdate()
                    if isFinal {
                        self.scheduleRecognizerRestart(locale: locale, session: session, taskID: taskID)
                    }
                }
            }
            if let error {
                let nsError = error as NSError
                if nsError.code == 301 || error.localizedDescription.lowercased().contains("cancel") { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isListening, self.sessionID == session,
                          self.taskIDs[locale] == taskID else { return }
                    self.audioLock.lock()
                    let failedRequest = self.requests.removeValue(forKey: locale)
                    self.audioLock.unlock()
                    failedRequest?.endAudio()
                    self.tasks.removeValue(forKey: locale)?.cancel()
                    if nsError.code == 203 {
                        self.scheduleRecognizerRestart(locale: locale, session: session, taskID: taskID, delay: 5.0)
                    } else {
                        self.handleRecognizerFailure(locale: locale, message: error.localizedDescription, session: session)
                    }
                }
            }
        }
        tasks[locale] = recognitionTask
        previousTask?.cancel()
    }

    private func scheduleRecognizerRestart(locale: String, session: UUID, taskID: UUID, delay: TimeInterval = 0.5) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isListening, self.sessionID == session,
                  self.taskIDs[locale] == taskID else { return }
            self.startRecognizer(locale: locale, session: session)
        }
    }

    private func handleRecognizerFailure(locale: String, message: String, session: UUID) {
        guard failedLocales.insert(locale).inserted else { return }
        let humanLanguage = locale == "ru-RU" ? "русский" : "английский"
        status = "Распознавание на \(humanLanguage) остановилось: \(message). Второй язык продолжает слушать."
    }

    private static func wakeCount(in transcript: String) -> Int {
        let pattern = #"(?i)дмитри[йи]?|дим[аы]?|димон|димка|димыч|димас|дмитро|димася"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(in: transcript, range: NSRange(transcript.startIndex..., in: transcript))
    }

    private static func playCount(in transcript: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: commandPattern) else { return 0 }
        return regex.numberOfMatches(in: transcript, range: NSRange(transcript.startIndex..., in: transcript))
    }

    private static func queryAfterWakeAndPlay(in transcript: String) -> String? {
        let wakePattern = #"(?i)дмитри[йи]?|дим[аы]?|димон|димка|димыч|димас|дмитро|димася"#
        guard let wakeRegex = try? NSRegularExpression(pattern: wakePattern),
              let commandRegex = try? NSRegularExpression(pattern: commandPattern) else { return nil }
        let nsText = transcript as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let wake = wakeRegex.matches(in: transcript, range: range).last,
              let command = commandRegex.matches(in: transcript, range: range).last,
              NSMaxRange(wake.range) <= command.range.location else { return nil }
        let commandText = String(nsText.substring(with: command.range))
        if let marker = actionMarker(for: commandText) { return marker }
        let query = nsText.substring(from: NSMaxRange(command.range)).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return query.isEmpty ? nil : query
    }

    private static func normalizeRussianNumerals(_ text: String) -> String {
        let substitutions: [(String, String)] = [
            ("нулевой", "0"), ("нулевая", "0"), ("нулевое", "0"), ("ноль", "0"),
            ("первый", "1"), ("первая", "1"), ("первое", "1"), ("один", "1"), ("одна", "1"), ("одно", "1"),
            ("второй", "2"), ("вторая", "2"), ("второе", "2"), ("два", "2"), ("две", "2"),
            ("третий", "3"), ("третья", "3"), ("третье", "3"), ("три", "3"),
            ("четвертый", "4"), ("четвертая", "4"), ("четвертое", "4"), ("четыре", "4"),
            ("пятый", "5"), ("пятая", "5"), ("пятое", "5"), ("пять", "5"),
            ("шестой", "6"), ("шестая", "6"), ("шестое", "6"), ("шесть", "6"),
            ("седьмой", "7"), ("седьмая", "7"), ("седьмое", "7"), ("семь", "7"),
            ("восьмой", "8"), ("восьмая", "8"), ("восьмое", "8"), ("восемь", "8"),
            ("девятый", "9"), ("девятая", "9"), ("девятое", "9"), ("девять", "9"),
            ("десятый", "10"), ("десятая", "10"), ("десятое", "10"), ("десять", "10")
        ]
        var result = " " + text.lowercased() + " "
        for (word, digit) in substitutions {
            result = result.replacingOccurrences(of: " \(word) ", with: " \(digit) ")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func actionMarker(for text: String) -> String? {
        if isPauseCommand(text) { return pauseCommandMarker }
        if isResumeCommand(text) { return resumeCommandMarker }
        if text.range(of: #"(?i)включи\s+(?:трек\s+)?(?:ещё\s+раз|еще\s+раз)|начни\s+сначала|с\s+самого\s+начала|по\s+новой|заново|сначала|restart(?:\s+track)?"#, options: .regularExpression) != nil {
            return restartCommandMarker
        }
        if text.range(of: #"(?i)следующий|следующую|дальше|\bnext\b|\bskip\b"#, options: .regularExpression) != nil { return nextCommandMarker }
        if text.range(of: #"(?i)предыдущий|предыдущую|прошлый|прошлую|назад|\bprevious\b"#, options: .regularExpression) != nil { return previousCommandMarker }
        return nil
    }

    private static func isResumeCommand(_ text: String) -> Bool {
        text.range(of: #"(?i)продолжай(?:те)?(?:\s+(?:музыку|воспроизведение))?|продолжи(?:ть)?(?:\s+(?:музыку|воспроизведение))?|возобнови(?:ть)?(?:\s+(?:музыку|воспроизведение))?|играй\s+дальше|\b(?:resume|continue)\b"#, options: .regularExpression) != nil
    }

    private static func isPauseCommand(_ text: String) -> Bool {
        text.range(of: #"(?i)поставь\s+(?:(?:музыку|воспроизведение)\s+)?(?:на\s+)?паузу|приостанови(?:ть)?(?:\s+(?:музыку|воспроизведение))?|останови(?:сь|ть)?(?:\s+(?:музыку|воспроизведение))?|выключи\s+(?:музыку|воспроизведение)|стоп|пауза|паузу|\b(?:pause|stop)\b"#, options: .regularExpression) != nil
    }

    private static func queryAfterPlayCommand(in transcript: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: commandPattern) else { return nil }
        let nsText = transcript as NSString
        guard let match = regex.matches(in: transcript, range: NSRange(location: 0, length: nsText.length)).last else { return nil }
        let command = nsText.substring(with: match.range)
        if let marker = actionMarker(for: command) { return marker }
        let result = nsText.substring(from: NSMaxRange(match.range)).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return result.isEmpty ? nil : result
    }

    private static func hasNativeTrigger(in transcript: String, locale: String) -> Bool {
        let pattern = locale == "ru-RU" ? #"включи|вруби|включить|поставь|запусти|играй"# : #"(?i)\b(?:play|put on|start)\b"#
        return transcript.range(of: pattern, options: .regularExpression) != nil
    }

    private func handleTranscriptUpdate() {
        for locale in locales {
            guard let (transcript, confidence) = latest[locale] else { continue }
            let wakeCount = Self.wakeCount(in: transcript)
            let oldWakeCount = wakeCounts[locale, default: 0]
            if wakeCount < oldWakeCount {
                wakeCounts[locale] = wakeCount
                triggerCounts[locale] = Self.playCount(in: transcript)
                wakeBaselines[locale] = wakeCount
                triggerBaselines[locale] = Self.playCount(in: transcript)
                pendingCandidates.removeValue(forKey: locale)
                continue
            }
            if wakeCount > oldWakeCount {
                wakeCounts[locale] = wakeCount
                guard waitingForWakeWord, Date().timeIntervalSince(lastWakeDetected) > 1.5 else {
                    wakeBaselines[locale] = wakeCount
                    triggerBaselines[locale] = Self.playCount(in: transcript)
                    continue
                }
                lastWakeDetected = Date()
                waitingForWakeWord = false
                waitingForPlayCommand = true
                wakeEpoch += 1
                pendingCandidates.removeAll()
                handledCommands.removeAll()
                debounce?.cancel()
                debounce = nil
                lastHeard = ""
                duckMusicForCommand()
                let epoch = wakeEpoch
                status = "Обращение услышано, жду «включи» или Play…"
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, self.wakeEpoch == epoch, self.waitingForPlayCommand else { return }
                    self.waitingForWakeWord = true
                    self.waitingForPlayCommand = false
                    self.pendingCandidates.removeAll()
                    self.restoreMusicVolume()
                    self.status = "Время ожидания команды истекло; скажи обращение ещё раз"
                }
                wakeTimeoutWork?.cancel()
                wakeTimeoutWork = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
                for otherLocale in locales {
                    let otherText = otherLocale == locale ? transcript : (latest[otherLocale]?.0 ?? "")
                    let oldWakeCount = Self.wakeCount(in: otherText)
                    wakeCounts[otherLocale] = oldWakeCount
                    wakeBaselines[otherLocale] = oldWakeCount
                    let oldPlayCount = Self.playCount(in: otherText)
                    triggerCounts[otherLocale] = oldPlayCount
                    triggerBaselines[otherLocale] = Self.queryAfterWakeAndPlay(in: otherText) == nil
                        ? oldPlayCount : max(0, oldPlayCount - 1)
                    pendingCandidates.removeValue(forKey: otherLocale)
                }
            }

            guard waitingForPlayCommand else { continue }
            let playCount = Self.playCount(in: transcript)
            if playCount < triggerCounts[locale, default: 0] {
                triggerCounts[locale] = playCount
                triggerBaselines[locale] = playCount
                alternatives[locale] = [(transcript, confidence)]
                pendingCandidates.removeValue(forKey: locale)
                continue
            }
            if playCount > triggerCounts[locale, default: 0] {
                triggerCounts[locale] = playCount
                triggerBaselines[locale] = playCount - 1
            }
            guard playCount >= triggerBaselines[locale, default: 0],
                  let query = Self.queryAfterPlayCommand(in: transcript), !query.isEmpty else { continue }
            pendingCandidates[locale] = (query, confidence)
            for (alternative, score) in alternatives[locale] ?? [] {
                guard let altQuery = Self.queryAfterPlayCommand(in: alternative), !altQuery.isEmpty else { continue }
                let existing = pendingCandidates[locale]
                if existing == nil || existing!.confidence < score {
                    pendingCandidates[locale] = (altQuery, score)
                }
            }
        }

        guard waitingForPlayCommand, !pendingCandidates.isEmpty else { return }
        let best = pendingCandidates.values.max { $0.confidence < $1.confidence }!
        lastHeard = best.query
        let epoch = wakeEpoch
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isListening, self.waitingForPlayCommand, self.wakeEpoch == epoch else { return }
            let candidates = Array(self.pendingCandidates.values.map(\.query))
            guard !candidates.isEmpty else { return }
            let query = self.pendingCandidates.values.max { $0.confidence < $1.confidence }!.query
            self.handledCommands.insert(query)
            self.wakeTimeoutWork?.cancel()
            self.waitingForPlayCommand = false
            self.status = "Ищу «\(query)» в пользовательских плейлистах…"
            let actionMarkers: [(String, String, String)] = [
                (Self.previousCommandMarker, "previous", "Переход к предыдущему треку"),
                (Self.nextCommandMarker, "next", "Включаю следующий трек"),
                (Self.restartCommandMarker, "restart", "Начинаю трек сначала")
            ]
            if let action = actionMarkers.first(where: { candidates.contains($0.0) }) {
                self.appleMusic.performTrackAction(action.1) { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        self.status = error ?? action.2
                        self.finishCommand()
                    }
                }
                return
            }
            if candidates.contains(Self.resumeCommandMarker) {
                self.appleMusic.resumePlayback { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        self.status = error ?? "Воспроизведение продолжено"
                        if let error { NotificationManager.notify(title: "Не удалось продолжить воспроизведение", body: error) }
                        self.finishCommand()
                    }
                }
                return
            }
            if candidates.contains(Self.pauseCommandMarker) {
                self.appleMusic.pausePlayback { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        self.status = error ?? "Воспроизведение приостановлено"
                        self.finishCommand()
                    }
                }
                return
            }
            let wantsPlaylist = candidates.contains { $0.range(of: Self.playlistPattern, options: .regularExpression) != nil }
            let normalizedCandidates = candidates.map { Self.normalizeRussianNumerals(Self.stripPlaylistWord(from: $0)) }.filter { !$0.isEmpty }
            if wantsPlaylist {
                self.status = "Ищу плейлист «\(normalizedCandidates.first ?? query)»…"
                self.appleMusic.findAndPlayPlaylist(candidates: normalizedCandidates) { [weak self] playlistName, error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let playlistName {
                            self.status = "Включён плейлист: \(playlistName)"
                        } else {
                            let message = error ?? "Не удалось найти похожий пользовательский плейлист"
                            self.status = message
                            NotificationManager.notify(title: "Плейлист не найден", body: message)
                        }
                        self.finishCommand()
                    }
                }
                return
            }
            self.appleMusic.findAndPlay(candidates: normalizedCandidates) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.currentTrack = result.track
                        self.currentArtwork = result.artwork
                        self.status = "Включено: \(result.track.title) — \(result.track.artist)"
                        self.hideMusicIfLaunchedByApp()
                    } else {
                        let isRussian = Locale.current.language.languageCode?.identifier == "ru"
                        let message = error ?? (isRussian ? "Не удалось найти трек в пользовательских плейлистах" : "No matching track was found in your playlists")
                        self.status = message
                        NotificationManager.notify(
                            title: isRussian ? "Трек не найден" : "Track not found",
                            body: message
                        )
                    }
                    self.finishCommand()
                }
            }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func finishCommand() {
        pendingCandidates.removeAll()
        lastHeard = ""
        waitingForWakeWord = true
        waitingForPlayCommand = false
        restoreMusicVolume()
    }

    private static func stripPlaylistWord(from text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: playlistPattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let stripped = regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        return stripped.replacingOccurrences(of: #"(?i)\b(?:мой|моя|моё|любимый|любимая|весь|вся|my|the)\b"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func duckMusicForCommand() {
        guard originalMusicVolume == nil, !volumeDuckPending else { return }
        volumeRestoreRequested = false
        volumeDuckPending = true
        appleMusic.duck(to: max(1, Int(duckVolume))) { [weak self] oldVolume in
            Task { @MainActor in
                guard let self else { return }
                self.volumeDuckPending = false
                self.originalMusicVolume = oldVolume
                if self.volumeRestoreRequested { self.restoreMusicVolume() }
            }
        }
    }

    private func restoreMusicVolume() {
        guard let volume = originalMusicVolume else {
            if volumeDuckPending { volumeRestoreRequested = true }
            return
        }
        originalMusicVolume = nil
        volumeRestoreRequested = false
        appleMusic.setVolume(volume)
    }

    private func startNowPlayingPolling() {
        nowPlayingTimer?.invalidate()
        nowPlayingTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appleMusic.fetchNowPlaying { [weak self] track, artwork in
                    Task { @MainActor in
                        guard let self, let track else { return }
                        self.currentTrack = track
                        self.currentArtwork = artwork
                    }
                }
            }
        }
    }

    private func hideMusicIfLaunchedByApp() {
        guard launchedMusicForSession else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first?.hide()
        launchedMusicForSession = false
    }

}
