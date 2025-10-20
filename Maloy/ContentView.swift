import SwiftUI
import AVFoundation
import Combine

struct ContentView: View {
    @StateObject private var audioManager = AudioManager()
    
    var body: some View {
        VStack(spacing: 20) {
            Text(audioManager.isListening ? "🎙️ Малой слушает..." : "🤖 Малой говорит...")
                .font(.title2).bold()
                .padding()
            
            if !audioManager.recognizedText.isEmpty {
                Text("👂 \(audioManager.recognizedText)")
                    .foregroundColor(.gray)
                    .padding()
            }
            
            if !audioManager.responseText.isEmpty {
                Text("💬 \(audioManager.responseText)")
                    .padding()
            }
        }
        .padding()
        .onAppear { audioManager.startConversation() }
    }
}

// MARK: - AUDIO MANAGER

final class AudioManager: NSObject, ObservableObject {
    @Published var recognizedText = ""
    @Published var responseText = ""
    @Published var isListening = false

    // API key is stored in Config.swift (not tracked in git for security)
    private let openAIKey = Config.openAIKey
    
    private let audioFilename = FileManager.default.temporaryDirectory.appendingPathComponent("input.wav")
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var silenceTimer: Timer?
    private var lastSpeechTime = Date()
    private var player: AVAudioPlayer?
    private var isProcessing = false
    private var isSpeaking = false

    // MARK: Старт диалога
    func startConversation() {
        say("Привет, я Малой! Чем займёмся, Фёдор?") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.startListening()
            }
        }
    }

    // MARK: Слушание (tap в родном формате + конвертация в 16kHz/mono Int16)
    func startListening() {
        guard !isSpeaking else { return }
        recognizedText = ""
        isListening = true
        isProcessing = false
        lastSpeechTime = Date()

        // Переключаемся на запись перед стартом движка
        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .default, options: [.allowBluetoothHFP])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session record error:", error)
        }

        let engine = AVAudioEngine()
        audioEngine = engine
        let input = engine.inputNode

        // Родной формат микрофона (важно: inputFormat, а не outputFormat)
        let inputFormat = input.inputFormat(forBus: 0)

        // Целевой формат для Whisper
        let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: 16_000,
                                          channels: 1,
                                          interleaved: true)!
        guard let converter = AVAudioConverter(from: inputFormat, to: desiredFormat) else {
            print("⚠️ Не удалось создать AVAudioConverter"); return
        }

        do {
            audioFile = try AVAudioFile(forWriting: audioFilename, settings: desiredFormat.settings)
        } catch {
            print("Audio file error:", error)
            return
        }

        // На всякий случай — чистим прежний tap
        input.removeTap(onBus: 0)

        // Tap ставим с format: nil (пусть система отдаёт родной формат)
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            guard let converted = AVAudioPCMBuffer(pcmFormat: desiredFormat,
                                                   frameCapacity: AVAudioFrameCount(1024)) else { return }

            var error: NSError?
            converter.convert(to: converted, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            if let e = error {
                print("Conversion error:", e)
                return
            }

            // ✅ Преобразуем в Float32 (чтобы точно записывалось без падений)
            guard let floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                  sampleRate: converted.format.sampleRate,
                                                  channels: converted.format.channelCount,
                                                  interleaved: false),
                  let floatBuffer = AVAudioPCMBuffer(pcmFormat: floatFormat,
                                                     frameCapacity: converted.frameCapacity)
            else { return }

            floatBuffer.frameLength = converted.frameLength
            for c in 0..<Int(converted.format.channelCount) {
                let src = converted.int16ChannelData![c]
                let dst = floatBuffer.floatChannelData![c]
                let count = Int(converted.frameLength)
                for i in 0..<count {
                    dst[i] = Float(src[i]) / Float(Int16.max)
                }
            }

            self.detectSpeech(buffer: floatBuffer)

            do {
                try self.audioFile?.write(from: floatBuffer)
            } catch {
                print("⚠️ File write error:", error)
            }
        }

        do {
            try engine.start()
        } catch {
            print("Engine start error:", error)
            return
        }

        startSilenceTimer()
        print("🎧 Listening started (mono 16kHz)")
    }

    // Остановка слушания (дергается таймером тишины)
    func stopListening() {
        isListening = false
        silenceTimer?.invalidate()
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        print("🛑 Listening stopped")
        transcribeAudio()
    }

    // MARK: Детектор речи (простая RMS-оценка)
    private func detectSpeech(buffer: AVAudioPCMBuffer) {
        guard !isProcessing, let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        let frame = Array(UnsafeBufferPointer(start: channel, count: count))
        let mean = frame.map { $0 * $0 }.reduce(0, +) / Float(max(count, 1))
        let rms = sqrt(mean)
        let avgPower = 20 * log10(max(rms, 1e-7)) // защита от -inf
        if avgPower > -45 { lastSpeechTime = Date() }
    }

    private func startSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            if Date().timeIntervalSince(self.lastSpeechTime) > 2.0 {
                self.stopListening()
            }
        }
    }

    // MARK: Whisper
    private func transcribeAudio() {
        isProcessing = true
        print("🧠 Whisper processing…")
        
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        req.httpMethod = "POST"
        req.addValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"input.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append((try? Data(contentsOf: audioFilename)) ?? Data())

        // model
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("whisper-1\r\n".data(using: .utf8)!)

        // язык — фиксируем русский
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("ru\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.startListening()
                }
                return
            }
            DispatchQueue.main.async {
                self.recognizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                print("🗣️ Распознано:", self.recognizedText)
                self.askGPT(self.recognizedText)
            }
        }.resume()
    }

    // MARK: GPT (Малой)
    private func askGPT(_ text: String) {
        guard !text.isEmpty else {
            self.isProcessing = false
            self.startListening()
            return
        }

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
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ],
            "max_tokens": 200
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let reply = msg["content"] as? String else {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.startListening()
                }
                return
            }
            DispatchQueue.main.async {
                self.responseText = reply
                print("💬 Малой:", reply)
                self.say(reply) {
                    self.isProcessing = false
                    self.startListening()
                }
            }
        }.resume()
    }

    // MARK: OpenAI TTS
    func say(_ text: String, completion: (() -> Void)? = nil) {
        guard let url = URL(string: "https://api.openai.com/v1/audio/speech") else { return }
        let json: [String: Any] = [
            "model": "gpt-4o-mini-tts",
            "voice": "alloy", // можно попробовать "verse", "shimmer", "soft"
            "input": text
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: json)

        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data else { return }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("speech.mp3")
            try? data.write(to: tmp)
            DispatchQueue.main.async { self.playAudio(from: tmp, completion: completion) }
        }.resume()
    }

    private func playAudio(from url: URL, completion: (() -> Void)? = nil) {
        do {
            // Переключаемся на воспроизведение перед TTS
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)

            isSpeaking = true
            let p = try AVAudioPlayer(contentsOf: url)
            player = p
            p.prepareToPlay()
            p.play()

            DispatchQueue.main.asyncAfter(deadline: .now() + p.duration + 0.5) {
                self.isSpeaking = false
                completion?()
            }
        } catch {
            print("TTS play error:", error)
            self.isSpeaking = false
            completion?()
        }
    }
}
