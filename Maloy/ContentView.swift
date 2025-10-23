import SwiftUI
import AVFoundation
import Combine

struct ContentView: View {
    @StateObject private var audioManager = AudioManager()
    @EnvironmentObject var mediaPlayerManager: MediaPlayerManager

    // Helper функции для кнопки
    private func getButtonText() -> String {
        if audioManager.isAutoMode {
            if audioManager.isProcessing {
                return "⏳ Обработка..."
            } else if audioManager.isListening {
                return "🛑 ПРЕРВАТЬ"
            } else {
                return "👂 Слушаю..."
            }
        } else {
            if audioManager.isListening {
                return "🛑 СТОП"
            } else if audioManager.isProcessing {
                return "⏳ Обработка..."
            } else {
                return "🎙️ ГОВОРИ"
            }
        }
    }

    private func getButtonColor() -> Color {
        if audioManager.isAutoMode {
            if audioManager.isProcessing {
                return .gray
            } else if audioManager.isListening {
                return .red
            } else {
                return .green
            }
        } else {
            if audioManager.isListening {
                return .red
            } else if audioManager.isProcessing {
                return .gray
            } else {
                return .blue
            }
        }
    }

    var body: some View {
        VStack(spacing: 30) {
            // Apple Music status indicator (top right corner)
            HStack {
                Spacer()
                if mediaPlayerManager.isAuthorized {
                    Text("✅ Apple Music")
                        .font(.system(size: 14))
                        .foregroundColor(.green)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 8)
                } else {
                    Text("⚠️ Нужен Apple Music")
                        .font(.system(size: 14))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 8)
                }
            }
            .padding(.horizontal)

            Text(audioManager.statusText)
                .font(.title).bold()
                .padding()

            if !audioManager.recognizedText.isEmpty {
                Text("👂 \(audioManager.recognizedText)")
                    .foregroundColor(.gray)
                    .padding()
                    .multilineTextAlignment(.center)
            }

            if !audioManager.responseText.isEmpty {
                Text("💬 \(audioManager.responseText)")
                    .padding()
                    .multilineTextAlignment(.center)
            }

            Spacer()

            // Кнопка управления
            Button(action: {
                if audioManager.isAutoMode {
                    // В авто режиме: ПРЕРВАТЬ всё
                    audioManager.interrupt()
                } else {
                    // В ручном режиме: старт/стоп
                    if audioManager.isListening {
                        audioManager.stopListening()
                    } else if !audioManager.isProcessing {
                        audioManager.startListening()
                    }
                }
            }) {
                Text(getButtonText())
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 320, height: 120)
                    .background(getButtonColor())
                    .cornerRadius(20)
            }
            .padding(.bottom, 20)

            // Маленькие кнопки управления
            HStack(spacing: 15) {
                // Кнопка переключения режима
                Button(action: {
                    audioManager.isAutoMode.toggle()
                    if audioManager.isAutoMode {
                        audioManager.startListeningAuto()
                    } else {
                        audioManager.interrupt()
                    }
                }) {
                    Text(audioManager.isAutoMode ? "🤖 Авто" : "✋ Ручной")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.orange)
                        .cornerRadius(10)
                }

                // Кнопка очистки истории
                Button(action: {
                    audioManager.clearHistory()
                }) {
                    Text("🗑️ Новый разговор")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.purple)
                        .cornerRadius(10)
                }
            }
            .padding(.bottom, 30)
        }
        .padding()
        .onAppear {
            audioManager.mediaPlayerManager = mediaPlayerManager
            audioManager.sayGreeting()
        }
    }
}

// MARK: - AUDIO MANAGER

final class AudioManager: NSObject, ObservableObject {
    @Published var recognizedText = ""
    @Published var responseText = ""
    @Published var statusText = "🤖 Малой"
    @Published var isListening = false
    @Published var isProcessing = false
    @Published var isAutoMode = true  // Автоматический режим по умолчанию

    // API key is stored in Config.swift (not tracked in git for security)
    private let openAIKey = Config.openAIKey

    // MediaPlayer manager (passed from ContentView)
    var mediaPlayerManager: MediaPlayerManager?

    private let audioFilename = FileManager.default.temporaryDirectory.appendingPathComponent("input.wav")
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var player: AVAudioPlayer?
    private var isSpeaking = false

    // VAD (Voice Activity Detection) параметры
    private var silenceTimer: Timer?
    private var lastSpeechTime = Date()
    private let silenceThreshold: TimeInterval = 1.5  // 1.5 сек тишины → стоп
    private let speechThreshold: Float = -40.0  // дБ, выше которого считаем речью

    // История разговора для контекста GPT
    private var conversationHistory: [[String: Any]] = []
    private let maxHistoryPairs = 4  // Храним последние 4 пары вопрос-ответ (8 сообщений)

    // Флаг для отслеживания музыкальных команд
    private var lastCommandWasMusic = false

    // MARK: Приветствие
    func sayGreeting() {
        // Запрещаем блокировку экрана пока приложение активно
        UIApplication.shared.isIdleTimerDisabled = true
        print("✅ Screen lock disabled - device will stay awake")

        statusText = "🗣️ Приветствие..."
        say("Привет, я Малой! Просто говори, я слушаю.") {
            DispatchQueue.main.async {
                if self.isAutoMode {
                    self.startListeningAuto()
                } else {
                    self.statusText = "💤 Жду команды"
                }
            }
        }
    }

    // MARK: Слушание (ручное управление с увеличенным буфером)
    func startListening() {
        guard !isSpeaking && !isProcessing else {
            print("⚠️ Cannot start: isSpeaking=\(isSpeaking), isProcessing=\(isProcessing)")
            return
        }

        print("\n========== НАЧАЛО ЗАПИСИ ==========")
        recognizedText = ""
        responseText = ""
        isListening = true
        statusText = "🎙️ Слушаю..."
        lastCommandWasMusic = false  // Сбрасываем флаг при новом прослушивании

        // Переключаемся на запись - используем .playAndRecord чтобы НЕ убивать Spotify
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .duckOthers, .mixWithOthers, .defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            print("✅ Audio session configured for recording (Spotify compatible)")
        } catch {
            print("❌ Audio session record error:", error)
            stopListening()
            return
        }

        let engine = AVAudioEngine()
        audioEngine = engine
        let input = engine.inputNode

        // Чистим прежний tap
        input.removeTap(onBus: 0)

        // Получаем формат микрофона (может быть любой - встроенный, наушники, bluetooth)
        let inputFormat = input.outputFormat(forBus: 0)

        print("🎤 Recording format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) ch, \(inputFormat.commonFormat.rawValue)")

        // Используем родной формат для tap (без конвертации)
        do {
            audioFile = try AVAudioFile(forWriting: audioFilename,
                                        settings: inputFormat.settings,
                                        commonFormat: .pcmFormatFloat32,
                                        interleaved: false)
            print("✅ Audio file created: \(audioFilename.path)")
        } catch {
            print("❌ Audio file error:", error)
            stopListening()
            return
        }

        // УВЕЛИЧЕННЫЙ bufferSize: 4096 → 8192 для более надежной записи
        // Это дает больше времени на запись буфера в файл
        input.installTap(onBus: 0, bufferSize: 8192, format: inputFormat) { [weak self] buffer, time in
            guard let self = self else { return }

            // Записываем буфер в файл с логированием ошибок
            do {
                try self.audioFile?.write(from: buffer)
            } catch {
                print("❌ File write error at time \(time.sampleTime): \(error)")
            }
        }

        do {
            try engine.start()
            print("✅ Audio engine started with buffer size 8192")
        } catch {
            print("❌ Engine start error:", error)
            stopListening()
            return
        }

        print("🎧 Recording... Press STOP when done")
    }

    // Остановка слушания (вызывается кнопкой)
    func stopListening() {
        guard isListening else { return }

        print("🛑 Stopping recording...")
        isListening = false
        statusText = "⏳ Обработка..."

        // Останавливаем движок и удаляем tap
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)

        // Останавливаем таймер VAD
        silenceTimer?.invalidate()
        silenceTimer = nil

        // Важно: закрываем файл перед обработкой
        audioFile = nil
        audioEngine = nil

        print("✅ Recording stopped")
        print("========== КОНЕЦ ЗАПИСИ ==========\n")

        transcribeAudio()
    }

    // MARK: Автоматическое прослушивание с VAD
    func startListeningAuto() {
        guard !isSpeaking && !isProcessing else {
            print("⚠️ Cannot start auto: isSpeaking=\(isSpeaking), isProcessing=\(isProcessing)")
            return
        }

        print("\n========== AUTO LISTENING (VAD) ==========")

        // ✅ ОЧИЩАЕМ переменные перед новой записью (как в ручном режиме)
        recognizedText = ""
        responseText = ""
        lastCommandWasMusic = false  // Сбрасываем флаг при новом прослушивании

        statusText = "👂 Слушаю..."
        lastSpeechTime = Date()  // Сбрасываем таймер

        // Переключаемся на запись - используем .playAndRecord чтобы НЕ убивать Spotify
        // .mixWithOthers позволяет Spotify играть в фоне
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .duckOthers, .mixWithOthers, .defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            print("✅ Audio session configured for VAD recording (Spotify compatible)")
        } catch {
            print("❌ Audio session VAD error:", error)
            return
        }

        let engine = AVAudioEngine()
        audioEngine = engine
        let input = engine.inputNode
        input.removeTap(onBus: 0)

        let inputFormat = input.outputFormat(forBus: 0)
        print("🎤 VAD format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) ch")

        // Создаём файл для записи
        do {
            audioFile = try AVAudioFile(forWriting: audioFilename,
                                        settings: inputFormat.settings,
                                        commonFormat: .pcmFormatFloat32,
                                        interleaved: false)
            print("✅ VAD audio file ready")
        } catch {
            print("❌ VAD file error:", error)
            return
        }

        // Устанавливаем tap с анализом громкости
        input.installTap(onBus: 0, bufferSize: 8192, format: inputFormat) { [weak self] buffer, time in
            guard let self = self else { return }

            // Записываем в файл
            do {
                try self.audioFile?.write(from: buffer)
            } catch {
                print("❌ VAD write error at \(time.sampleTime): \(error)")
            }

            // Анализируем громкость (RMS - Root Mean Square)
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frames = buffer.frameLength
            var sum: Float = 0.0
            for i in 0..<Int(frames) {
                let sample = channelData[i]
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(frames))
            let db = 20 * log10(rms)

            // Если громкость выше порога → обновляем время последней речи
            if db > self.speechThreshold {
                DispatchQueue.main.async {
                    self.lastSpeechTime = Date()
                    if !self.isListening {
                        self.isListening = true
                        self.statusText = "🎙️ Записываю..."
                        print("🗣️ Speech detected! (level: \(String(format: "%.1f", db))dB)")
                    }
                }
            }
        }

        do {
            try engine.start()
            print("✅ VAD engine started")
        } catch {
            print("❌ VAD engine error:", error)
            return
        }

        // Запускаем таймер проверки тишины (каждые 0.15 сек)
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            let silenceDuration = Date().timeIntervalSince(self.lastSpeechTime)

            // Если было начато прослушивание И прошло достаточно тишины → останавливаем
            if self.isListening && silenceDuration > self.silenceThreshold {
                print("🔇 Silence detected for \(String(format: "%.1f", silenceDuration))s → stopping")
                self.stopListeningAuto()
            }
        }
    }

    // Остановка автоматического прослушивания
    func stopListeningAuto() {
        guard isListening else { return }

        print("🛑 Auto-stopping recording...")
        isListening = false

        // МГНОВЕННАЯ РЕАКЦИЯ - говорим сразу после остановки записи!
        let quickReactions = ["Ага", "Понял", "Так-так", "Ясно", "Окей", "Хм", "Секунду"]
        let reaction = quickReactions.randomElement() ?? "Ага"

        print("💬 Quick reaction (before transcription): \"\(reaction)\"")

        // Говорим реакцию СРАЗУ, не ждём
        say(reaction) {
            DispatchQueue.main.async {
                self.statusText = "🧠 Распознаю..."
            }
        }

        // Останавливаем движок
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)

        // Останавливаем таймер
        silenceTimer?.invalidate()
        silenceTimer = nil

        // Закрываем файл
        audioFile = nil
        audioEngine = nil

        print("✅ Auto-recording stopped")
        print("========== END VAD ==========\n")

        transcribeAudio()
    }

    // Прерывание (остановка всего)
    func interrupt() {
        print("🛑 INTERRUPT - stopping everything")

        // Останавливаем запись
        if isListening {
            audioEngine?.stop()
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioFile = nil
            audioEngine = nil
            isListening = false
        }

        // Останавливаем таймер
        silenceTimer?.invalidate()
        silenceTimer = nil

        // Останавливаем воспроизведение TTS
        player?.stop()
        isSpeaking = false

        // Останавливаем музыку
        mediaPlayerManager?.stop()

        isProcessing = false
        statusText = "🛑 Прервано"

        // Если авто режим → перезапускаем прослушивание через секунду
        if isAutoMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.startListeningAuto()
            }
        }
    }

    // MARK: Очистка истории разговора
    func clearHistory() {
        conversationHistory.removeAll()
        recognizedText = ""
        responseText = ""
        statusText = "🗑️ История очищена"
        print("🗑️ Conversation history cleared")

        // Через секунду возвращаемся в обычный статус
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if self.isAutoMode && !self.isListening && !self.isProcessing {
                self.statusText = "👂 Слушаю..."
            } else if !self.isListening && !self.isProcessing {
                self.statusText = "💤 Жду команды"
            }
        }
    }

    // MARK: Whisper (с детальным логированием)
    private func transcribeAudio() {
        isProcessing = true
        statusText = "🧠 Распознаю речь..."
        print("\n========== WHISPER API ==========")

        guard let audioData = try? Data(contentsOf: audioFilename) else {
            print("❌ Cannot read audio file")
            DispatchQueue.main.async {
                self.statusText = "❌ Ошибка чтения файла"
                self.isProcessing = false
            }
            return
        }

        print("📦 Audio file size: \(audioData.count / 1024)KB")

        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        req.httpMethod = "POST"
        req.addValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"input.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)

        // model
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("whisper-1\r\n".data(using: .utf8)!)

        // язык — фиксируем русский
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("ru\r\n".data(using: .utf8)!)

        // prompt — подсказка для контекста (уменьшает галлюцинации)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".data(using: .utf8)!)
        body.append("Разговор ребенка с голосовым помощником. Вопросы про учебу, космос, игры.\r\n".data(using: .utf8)!)

        // temperature — точность распознавания (0 = максимально точно)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"temperature\"\r\n\r\n".data(using: .utf8)!)
        body.append("0.0\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        print("📤 Sending to Whisper API...")
        let startTime = Date()

        URLSession.shared.dataTask(with: req) { data, response, error in
            let elapsed = Date().timeIntervalSince(startTime)
            print("⏱️ Whisper response time: \(String(format: "%.1f", elapsed))s")

            if let error = error {
                print("❌ Whisper error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.statusText = "❌ Ошибка сети"
                    self.isProcessing = false
                }
                return
            }

            guard let data = data else {
                print("❌ No data received")
                DispatchQueue.main.async {
                    self.statusText = "❌ Нет данных"
                    self.isProcessing = false
                }
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("❌ Cannot parse JSON")
                if let responseString = String(data: data, encoding: .utf8) {
                    print("Raw response: \(responseString)")
                }
                DispatchQueue.main.async {
                    self.statusText = "❌ Ошибка API"
                    self.isProcessing = false
                }
                return
            }

            guard let text = json["text"] as? String else {
                print("❌ No 'text' field in response")
                print("JSON: \(json)")
                DispatchQueue.main.async {
                    self.statusText = "❌ Нет текста"
                    self.isProcessing = false
                }
                return
            }

            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            print("✅ Recognized: \"\(trimmedText)\"")

            // ✅ ФИЛЬТРАЦИЯ МУСОРНЫХ РАСПОЗНАВАНИЙ (Whisper галлюцинации)
            let junkPhrases = [
                "тема животные и фрукты",
                "вопросы про учебу",
                "кино и спорт",
                "спасибо за просмотр",
                "подписывайтесь на канал",
                "ставьте лайки",
                "субтитры",
                "продолжение следует",
                "музыка",
                "аплодисменты"
            ]

            let lowercased = trimmedText.lowercased()
            let isJunk = junkPhrases.contains { lowercased.contains($0) }

            if isJunk {
                print("⚠️ JUNK detected - ignoring Whisper hallucination: \"\(trimmedText)\"")
                DispatchQueue.main.async {
                    self.statusText = "🤷 Не расслышал"
                    self.isProcessing = false

                    // В авто режиме → сразу продолжаем слушать
                    if self.isAutoMode {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.startListeningAuto()
                        }
                    }
                }
                print("========== END WHISPER ==========\n")
                return
            }

            if trimmedText.isEmpty || trimmedText.count < 2 {
                print("⚠️ Too short or empty - nothing heard")
                DispatchQueue.main.async {
                    self.statusText = "🤷 Ничего не услышал"
                    self.recognizedText = "(пусто)"
                    self.isProcessing = false

                    // В авто режиме → продолжаем слушать
                    if self.isAutoMode {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.startListeningAuto()
                        }
                    }
                }
                print("========== END WHISPER ==========\n")
                return
            }

            print("========== END WHISPER ==========\n")

            DispatchQueue.main.async {
                self.recognizedText = trimmedText
                self.askGPT(trimmedText)
            }
        }.resume()
    }

    // MARK: GPT (с историей разговора)
    private func askGPT(_ text: String) {
        // Allow empty text only for function call follow-ups (when conversation history has function results)
        if text.isEmpty && conversationHistory.isEmpty {
            print("⚠️ Empty text for GPT")
            DispatchQueue.main.async {
                self.isProcessing = false
                self.statusText = "💤 Жду команды"
            }
            return
        }

        // Реакция уже была сказана в stopListeningAuto()
        // Сразу показываем статус "думаю"
        DispatchQueue.main.async {
            self.statusText = "🤔 Думаю..."
        }

        print("\n========== GPT API ==========")
        print("📝 User input: \"\(text)\"")

        let url = URL(string: "https://api.openai.com/v1/chat/completions")!

        // ✅ СОКРАЩЕННЫЙ ПРОМПТ (экономия токенов, быстрее обработка)
        var systemPrompt = """
        Ты Малой — голосовой помощник. Говоришь с Фёдором (15 лет, незрячий, 8 класс).
        Стиль: на равных, без сюсюканья, современный сленг OK, можно шутить.
        Описывая предметы → упоминай форму, размер, текстуру (он незрячий).
        Отвечай кратко (2-4 фразы). Английские слова можно.
        """

        if mediaPlayerManager?.isAuthorized == true {
            systemPrompt += """

            ВАЖНО: У тебя есть Apple Music функции. Когда пользователь просит включить музыку - СРАЗУ вызывай функцию, НЕ спрашивай подтверждения.
            Примеры:
            - "Включи Моргенштерна" → вызови music_search_and_play("Моргенштерн")
            - "Включи The Head and the Heart" → вызови music_search_and_play("The Head and the Heart")
            - "Поставь на паузу" / "Стоп" / "Останови" → вызови music_pause
            - "Следующий трек" / "Дальше" / "Некст" → вызови music_next
            - "Продолжи" / "Играй" → вызови music_play

            КРИТИЧЕСКИ ВАЖНО: НЕ ПЕРЕВОДИ названия артистов и песен! Передавай их В ТОЧНОСТИ как услышал!
            - "Включи The Head and the Heart" → music_search_and_play("The Head and the Heart") ✅
            - "Включи The Head and the Heart" → music_search_and_play("Голова и Сердце") ❌ НЕПРАВИЛЬНО!
            - "Включи Coldplay" → music_search_and_play("Coldplay") ✅
            - "Включи Imagine Dragons" → music_search_and_play("Imagine Dragons") ✅

            ОЧЕНЬ ВАЖНО: Слова "стоп", "останови", "хватит", "выключи музыку" → ВСЕГДА вызывай music_pause!

            Когда включаешь музыку - отвечай названием артиста и трека БЕЗ ПЕРЕВОДА.
            Примеры правильных ответов:
            - Если включил Моргенштерна "Cadillac" → скажи "Моргенштерн, Кадиллак"
            - Если включил Coldplay "Yellow" → скажи "Coldplay, Yellow" (НЕ "Колдплей, Йеллоу"!)
            - Если включил The Head and the Heart → скажи "The Head and the Heart, [название трека]"
            - НИКОГДА не говори "Включаю", "Лови", "Играет" - ТОЛЬКО название!
            """
        }

        // ✅ ДОБАВЛЯЕМ ТЕКУЩИЙ ВОПРОС В ИСТОРИЮ (только если не пустой)
        if !text.isEmpty {
            conversationHistory.append(["role": "user", "content": text])
        }

        // ✅ СКОЛЬЗЯЩЕЕ ОКНО: удаляем старые пары, если история слишком длинная
        // Каждая пара = user + assistant = 2 сообщения
        // Храним maxHistoryPairs * 2 = 8 сообщений (4 пары)
        while conversationHistory.count > maxHistoryPairs * 2 {
            conversationHistory.removeFirst(2)  // Удаляем старейшую пару (user + assistant)
            print("🗑️ Removed oldest conversation pair (sliding window)")
        }

        // ✅ ФОРМИРУЕМ MESSAGES: системный промпт + вся история
        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt]
        ]
        messages.append(contentsOf: conversationHistory)

        print("📚 Conversation history: \(conversationHistory.count) messages (\(conversationHistory.count / 2) pairs)")

        // Music tools (only if authorized) - using new tools format for gpt-4o-mini
        var tools: [[String: Any]] = []
        if mediaPlayerManager?.isAuthorized == true {
            tools = [
                [
                    "type": "function",
                    "function": [
                        "name": "music_search_and_play",
                        "description": "НЕМЕДЛЕННО включить музыку из Apple Music. Используй когда пользователь говорит 'включи', 'поставь', 'играй' + название артиста/песни. НЕ спрашивай подтверждения - сразу вызывай эту функцию.",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "query": [
                                    "type": "string",
                                    "description": "Название артиста или песни (например: 'Моргенштерн', 'Imagine Dragons', 'Shape of You')"
                                ]
                            ],
                            "required": ["query"]
                        ]
                    ]
                ],
                [
                    "type": "function",
                    "function": [
                        "name": "music_play",
                        "description": "Продолжить воспроизведение музыки",
                        "parameters": ["type": "object", "properties": [:]]
                    ]
                ],
                [
                    "type": "function",
                    "function": [
                        "name": "music_pause",
                        "description": "Поставить музыку на паузу или остановить",
                        "parameters": ["type": "object", "properties": [:]]
                    ]
                ],
                [
                    "type": "function",
                    "function": [
                        "name": "music_next",
                        "description": "Переключить на следующий трек",
                        "parameters": ["type": "object", "properties": [:]]
                    ]
                ],
                [
                    "type": "function",
                    "function": [
                        "name": "music_previous",
                        "description": "Вернуться к предыдущему треку",
                        "parameters": ["type": "object", "properties": [:]]
                    ]
                ]
            ]
        }

        var body: [String: Any] = [
            "model": "gpt-4o-mini",  // Изменено с gpt-3.5-turbo - лучше работает с function calling
            "messages": messages,
            "max_tokens": 150
        ]

        if !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = "auto"
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        print("📤 Sending to GPT...")
        print("🔍 DEBUG - Request body keys: \(body.keys.sorted())")
        print("🔍 DEBUG - Model: \(body["model"] as? String ?? "unknown")")
        print("🔍 DEBUG - Has tools: \(!tools.isEmpty)")
        print("🔍 DEBUG - Messages count: \((body["messages"] as? [Any])?.count ?? 0)")
        let startTime = Date()

        URLSession.shared.dataTask(with: req) { data, response, error in
            let elapsed = Date().timeIntervalSince(startTime)
            print("⏱️ GPT response time: \(String(format: "%.1f", elapsed))s")

            if let error = error {
                print("❌ GPT error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.statusText = "❌ Ошибка GPT"
                    self.isProcessing = false
                }
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("❌ Cannot parse GPT response")
                DispatchQueue.main.async {
                    self.statusText = "❌ Ошибка парсинга"
                    self.isProcessing = false
                }
                return
            }

            guard let choices = json["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any] else {
                print("❌ No message in GPT response")
                print("JSON: \(json)")
                DispatchQueue.main.async {
                    self.statusText = "❌ Нет ответа"
                    self.isProcessing = false
                }
                return
            }

            // DEBUG: Print full GPT response to see what's happening
            print("🔍 DEBUG - Full GPT message: \(msg)")
            print("🔍 DEBUG - Has tool_calls: \(msg["tool_calls"] != nil)")
            print("🔍 DEBUG - Content: \(msg["content"] as? String ?? "nil")")
            if !tools.isEmpty {
                print("🔍 DEBUG - Tools were sent: \(tools.count) tools")
            } else {
                print("🔍 DEBUG - No tools were sent in request")
            }

            // Check if GPT wants to call a tool (new format)
            if let toolCalls = msg["tool_calls"] as? [[String: Any]],
               let firstToolCall = toolCalls.first,
               let function = firstToolCall["function"] as? [String: Any],
               let functionName = function["name"] as? String,
               let argumentsString = function["arguments"] as? String {

                let toolCallId = firstToolCall["id"] as? String ?? "unknown"
                print("🎵 GPT wants to call tool: \(functionName)")
                print("📝 Tool call ID: \(toolCallId)")
                print("📝 Arguments: \(argumentsString)")

                // Execute Music function
                self.executeMusicFunction(name: functionName, arguments: argumentsString) { result in
                    // After function execution, ask GPT again with tool result (new format)
                    self.conversationHistory.append([
                        "role": "assistant",
                        "tool_calls": toolCalls
                    ] as [String : Any])
                    self.conversationHistory.append([
                        "role": "tool",
                        "tool_call_id": toolCallId,
                        "name": functionName,
                        "content": result
                    ])

                    // Recursive call to get final response
                    self.askGPT("")
                }
                return
            }

            // Normal text response
            guard let reply = msg["content"] as? String else {
                print("❌ No content in GPT response")
                print("JSON: \(json)")
                DispatchQueue.main.async {
                    self.statusText = "❌ Нет ответа"
                    self.isProcessing = false
                }
                return
            }

            print("✅ GPT reply: \"\(reply)\"")

            // ✅ ДОБАВЛЯЕМ ОТВЕТ GPT В ИСТОРИЮ
            self.conversationHistory.append(["role": "assistant", "content": reply])
            print("📚 Added assistant response to history (now \(self.conversationHistory.count) messages)")
            print("========== END GPT ==========\n")

            // МОМЕНТАЛЬНО показываем текст ответа пользователю
            DispatchQueue.main.async {
                self.responseText = reply
                self.statusText = "🗣️ Готовлю озвучку..."
            }

            // TTS запускается параллельно (не блокирует UI)
            self.say(reply) {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    // Если авто режим → продолжаем слушать
                    // НО: если только что включили музыку - НЕ запускаем авто-прослушивание
                    if self.isAutoMode && !self.lastCommandWasMusic {
                        self.startListeningAuto()
                    } else {
                        self.statusText = "💤 Жду команды"
                        // Сбрасываем флаг музыки для следующей команды
                        self.lastCommandWasMusic = false
                    }
                }
            }
        }.resume()
    }

    // MARK: - Music Function Execution
    private func executeMusicFunction(name: String, arguments: String, completion: @escaping (String) -> Void) {
        guard let music = mediaPlayerManager else {
            completion("{\"error\": \"MusicKit not initialized\"}")
            return
        }

        // Parse arguments JSON
        guard let argsData = arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] else {
            completion("{\"error\": \"Invalid arguments\"}")
            return
        }

        print("🎵 Executing Music function: \(name)")

        // Устанавливаем флаг для команд воспроизведения (кроме паузы)
        if name == "music_search_and_play" || name == "music_play" || name == "music_next" || name == "music_previous" {
            self.lastCommandWasMusic = true
        }

        switch name {
        case "music_search_and_play":
            guard let query = args["query"] as? String else {
                completion("{\"error\": \"Missing query parameter\"}")
                return
            }

            music.searchAndPlay(query: query) { success, message in
                if success {
                    completion("{\"success\": true, \"message\": \"\(message)\"}")
                } else {
                    completion("{\"success\": false, \"message\": \"\(message)\"}")
                }
            }

        case "music_play":
            music.play { success, message in
                completion("{\"success\": \(success), \"message\": \"\(message)\"}")
            }

        case "music_pause":
            music.pause { success, message in
                completion("{\"success\": \(success), \"message\": \"\(message)\"}")
            }

        case "music_next":
            music.next { success, message in
                completion("{\"success\": \(success), \"message\": \"\(message)\"}")
            }

        case "music_previous":
            music.previous { success, message in
                completion("{\"success\": \(success), \"message\": \"\(message)\"}")
            }

        default:
            completion("{\"error\": \"Unknown function: \(name)\"}")
        }
    }

    // MARK: TTS (оптимизировано для скорости)
    func say(_ text: String, completion: (() -> Void)? = nil) {
        print("\n========== TTS API ==========")
        print("💬 Text to speak: \"\(text)\"")

        // Обновляем статус только в main thread
        DispatchQueue.main.async {
            self.statusText = "🗣️ Говорю..."
        }

        guard let url = URL(string: "https://api.openai.com/v1/audio/speech") else {
            print("❌ Invalid TTS URL")
            completion?()
            return
        }

        let json: [String: Any] = [
            "model": "gpt-4o-mini-tts",
            "voice": "alloy",
            "input": text,
            "speed": 1.15  // Увеличили скорость с 1.0 до 1.15 для быстрой речи
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: json)

        print("📤 Requesting TTS...")
        let startTime = Date()

        URLSession.shared.dataTask(with: req) { data, response, error in
            let elapsed = Date().timeIntervalSince(startTime)
            print("⏱️ TTS response time: \(String(format: "%.1f", elapsed))s")

            if let error = error {
                print("❌ TTS error:", error.localizedDescription)
                DispatchQueue.main.async {
                    self.statusText = "❌ Ошибка TTS"
                }
                completion?()
                return
            }

            guard let data = data, !data.isEmpty else {
                print("❌ Empty TTS response")
                DispatchQueue.main.async {
                    self.statusText = "❌ Нет аудио"
                }
                completion?()
                return
            }

            print("✅ TTS received (\(data.count / 1024)KB)")

            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("speech.mp3")
            do {
                try data.write(to: tmp, options: .atomic)
                print("✅ TTS file saved: \(tmp.path)")
                DispatchQueue.main.async {
                    self.playAudio(from: tmp, completion: completion)
                }
            } catch {
                print("❌ TTS write error:", error)
                completion?()
            }
        }.resume()
    }

    private func playAudio(from url: URL, completion: (() -> Void)? = nil) {
        print("🔊 Starting playback...")

        do {
            // Используем .playAndRecord с .duckOthers чтобы НЕ останавливать Spotify
            // .duckOthers понижает громкость другого аудио (Spotify) вместо остановки
            // .mixWithOthers позволяет играть одновременно с другими приложениями
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker, .mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            print("✅ Audio session configured for TTS (ducking Spotify)")

            isSpeaking = true
            let p = try AVAudioPlayer(contentsOf: url)
            player = p

            p.prepareToPlay()
            let success = p.play()

            if !success {
                print("❌ Failed to start audio playback")
                self.isSpeaking = false
                DispatchQueue.main.async {
                    self.statusText = "❌ Ошибка воспроизведения"
                }
                completion?()
                return
            }

            print("🔊 Playing audio (duration: \(String(format: "%.1f", p.duration))s)")

            // Ждем окончания + небольшой буфер
            DispatchQueue.main.asyncAfter(deadline: .now() + p.duration + 0.3) {
                print("✅ Playback finished")
                print("========== END TTS ==========\n")
                self.isSpeaking = false

                // После TTS деактивируем аудио-сессию с уведомлением других приложений
                // Это восстановит громкость Spotify
                do {
                    try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                    print("🔊 Audio session deactivated, Spotify should resume normal volume")
                } catch {
                    print("⚠️ Could not deactivate audio session: \(error)")
                }

                completion?()
            }
        } catch {
            print("❌ TTS play error:", error)
            self.isSpeaking = false
            DispatchQueue.main.async {
                self.statusText = "❌ Ошибка плеера"
            }
            completion?()
        }
    }
}
