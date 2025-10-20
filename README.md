# Maloy - Voice Assistant for Visually Impaired Children

Maloy is a SwiftUI-based iOS voice assistant designed specifically for visually impaired students. The app uses OpenAI's AI technologies to provide an interactive, voice-first experience with child-friendly responses in Russian.

## Features

- 🎙️ **Voice Recognition** - Whisper API for accurate Russian speech-to-text
- 💬 **Conversational AI** - GPT-4o-mini with child-appropriate responses
- 🔊 **Text-to-Speech** - Natural-sounding voice responses
- 👂 **Smart Listening** - Automatic silence detection (stops after 2 seconds of quiet)
- ♿ **Accessibility-First** - Designed for visually impaired users with tactile descriptions

## Requirements

- iOS 26.0+
- Xcode 26.0+
- OpenAI API Key ([Get one here](https://platform.openai.com/api-keys))

## Setup

1. **Clone the repository:**
   ```bash
   git clone https://github.com/YOUR_USERNAME/Maloy.git
   cd Maloy
   ```

2. **Configure API Key:**
   ```bash
   cp Maloy/Config.swift.example Maloy/Config.swift
   ```

   Then edit `Maloy/Config.swift` and add your OpenAI API key.

3. **Open in Xcode:**
   ```bash
   open Maloy.xcodeproj
   ```

4. **Build and Run** (Cmd+R)

## How It Works

1. App starts with a friendly greeting: "Привет, я Малой!"
2. Listens for user's voice input
3. Converts speech to text using Whisper API
4. Sends text to GPT-4o-mini for a child-friendly response
5. Converts response to speech and plays it back
6. Automatically resumes listening for next question

## Architecture

- **SwiftUI** - Modern declarative UI
- **AVFoundation** - Audio recording and playback
- **Combine** - Reactive state management
- **OpenAI APIs** - Whisper (STT), GPT-4o-mini (Chat), TTS (Speech)

For detailed architecture documentation, see [CLAUDE.md](CLAUDE.md).

## Privacy & Security

- ⚠️ API keys are stored locally in `Config.swift` (excluded from git)
- Audio recordings are temporary and deleted after processing
- No data is stored permanently on device
- All AI processing happens via OpenAI APIs

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is created for educational purposes.

## Acknowledgments

- Built with [Claude Code](https://claude.com/claude-code)
- Powered by [OpenAI APIs](https://platform.openai.com/)
