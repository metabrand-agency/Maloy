import SwiftUI
import AVFoundation
import Combine

struct ContentView: View {
    @StateObject private var audioManager = AudioManager()

    var body: some View {
        VStack(spacing: 30) {
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

            // Большая кнопка - можно остановить вручную
            Button(action: {
                if audioManager.isListening {
                    audioManager.stopListening()
                } else if !audioManager.isProcessing {
                    audioManager.startListening()
                }
            }) {
                Text(audioManager.isListening ? "🛑 СТОП" : (audioManager.isProcessing ? "⏳ Обработка..." : "🎙️ ГОВОРИ"))
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 320, height: 120)
                    .background(audioManager.isListening ? Color.red : (audioManager.isProcessing ? Color.gray : Color.blue))
                    .cornerRadius(20)
            }
            .disabled(audioManager.isProcessing)
            .padding(.bottom, 50)
        }
        .padding()
        .onAppear { audioManager.sayGreeting() }
    }
}

// MARK: - AUDIO MANAGER

final class AudioManager: NSObject, ObservableObject {
    @Published var recognizedText = ""
    @Published var responseText = ""
    @Published var statusText = "🤖 Малой"
    @Published var isListening = false
    @Published var isProcessing = false
    @Published var recordingTimeLeft = 5

    // API key is stored in Config.swift (not tracked in git for security)
    private let openAIKey = Config.openAIKey

    private let audioFilename = FileManager.default.temporaryDirectory.appendingPathComponent("input.wav")
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var player: AVAudioPlayer?
    private var isSpeaking = false
    private var recordingTimer: Timer?
    private let recordingDuration = 5 // секунд для записи

    // MARK: Приветствие
    func sayGreeting() {
        statusText = "🗣️ Приветствие..."
        say("Привет, я Малой! Нажми кнопку и говори.") {
            DispatchQueue.main.async {
                self.statusText = "💤 Жду команды"
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

        // Переключаемся на запись перед стартом движка
        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .default, options: [.allowBluetoothHFP, .duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            print("✅ Audio session configured for recording")
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

        // Важно: закрываем файл перед обработкой
        audioFile = nil
        audioEngine = nil

        print("✅ Recording stopped")
        print("========== КОНЕЦ ЗАПИСИ ==========\n")

        transcribeAudio()
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
            print("========== END WHISPER ==========\n")

            if trimmedText.isEmpty {
                print("⚠️ Empty recognition - nothing heard")
                DispatchQueue.main.async {
                    self.statusText = "🤷 Ничего не услышал"
                    self.recognizedText = "(пусто)"
                    self.isProcessing = false
                }
                return
            }

            DispatchQueue.main.async {
                self.recognizedText = trimmedText
                self.askGPT(trimmedText)
            }
        }.resume()
    }

    // MARK: GPT (оптимизировано для скорости)
    private func askGPT(_ text: String) {
        guard !text.isEmpty else {
            print("⚠️ Empty text for GPT")
            DispatchQueue.main.async {
                self.isProcessing = false
                self.statusText = "💤 Жду команды"
            }
            return
        }

        // Сразу показываем статус
        DispatchQueue.main.async {
            self.statusText = "🤔 Думаю..."
        }

        print("\n========== GPT API ==========")
        print("📝 User input: \"\(text)\"")

        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        let systemPrompt = """
        Ты голосовой ассистент по имени Малой. Ты крутой и весёлый.
        Разговаривай с ребёнком 5 класса просто, дружелюбно и коротко.
        Ребёнка зовут Фёдор. Он незрячий. Поэтому описывай предметы тактильно — форму, размер, ощущения.
        Если вопрос длинный — отвечай чуть подробнее.
        Если просят почитать книгу — читай частями (по 3–4 предложения).
        Говори по-русски. Иногда вставляй английские выражения с коротким объяснением.
        Отвечай не дольше нескольких предложений.
        """

        let body: [String: Any] = [
            "model": "gpt-3.5-turbo",  // Переключились с gpt-4o-mini на gpt-3.5-turbo (быстрее в 3-4 раза!)
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ],
            "max_tokens": 80
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        print("📤 Sending to GPT...")
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
                  let msg = choices.first?["message"] as? [String: Any],
                  let reply = msg["content"] as? String else {
                print("❌ No content in GPT response")
                print("JSON: \(json)")
                DispatchQueue.main.async {
                    self.statusText = "❌ Нет ответа"
                    self.isProcessing = false
                }
                return
            }

            print("✅ GPT reply: \"\(reply)\"")
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
                    self.statusText = "💤 Жду команды"
                }
            }
        }.resume()
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
            // Переключаемся на воспроизведение перед TTS
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            print("✅ Audio session configured for playback")

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
