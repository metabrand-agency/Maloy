# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Maloy** is a SwiftUI-based iOS voice assistant application designed for a visually impaired fifth-grade student named Fedor. The app uses OpenAI's Whisper (speech-to-text), GPT-4o-mini (conversation), and TTS (text-to-speech) to create an interactive voice assistant that responds in Russian with simple, tactile descriptions.

- **Target Platform**: iOS 26.0+
- **Language**: Swift 5.0
- **Framework**: SwiftUI with Combine
- **Architecture**: Single-view app with `AudioManager` handling all voice interaction logic
- **Bundle ID**: `Metabrand.Maloy`

## Initial Setup

### First Time Setup

**1. Configure API Key:**
```bash
# Copy the example config file
cp Maloy/Config.swift.example Maloy/Config.swift

# Edit Config.swift and add your OpenAI API key
# Get your key from: https://platform.openai.com/api-keys
```

**2. Open in Xcode:**
```bash
open Maloy.xcodeproj
```

The `Config.swift` file is excluded from git (via `.gitignore`) to protect your API key.

## Development Commands

### Building and Running

**Open in Xcode:**
```bash
open Maloy.xcodeproj
```

**Build from command line:**
```bash
xcodebuild -project Maloy.xcodeproj -scheme Maloy -configuration Debug
```

**Build for Release:**
```bash
xcodebuild -project Maloy.xcodeproj -scheme Maloy -configuration Release
```

**Clean build folder:**
```bash
xcodebuild clean -project Maloy.xcodeproj -scheme Maloy
```

### Running on Simulator/Device

The app requires microphone permissions and works best on a physical device. To run:
1. Open `Maloy.xcodeproj` in Xcode
2. Select your target device (iPhone or iPad)
3. Press Cmd+R to build and run

## Architecture

### Core Components

**MaloyApp.swift**
- Main app entry point using `@main` attribute
- Launches `ContentView` in a `WindowGroup`

**ContentView.swift**
- Single view containing all UI and business logic
- Displays conversation state (listening vs. speaking)
- Shows recognized speech and AI responses
- Contains `AudioManager` class that handles:
  - Audio recording with AVAudioEngine
  - Real-time voice activity detection (RMS-based)
  - Speech-to-text via OpenAI Whisper API
  - GPT-4o-mini chat completions
  - Text-to-speech via OpenAI TTS API
  - Audio session management (switching between record/playback modes)

### Audio Processing Flow

1. **Recording**: Native microphone format → convert to 16kHz mono Int16 → write to WAV file
2. **Voice Activity Detection**: Monitor RMS power levels; stop after 2 seconds of silence
3. **Transcription**: Send WAV to Whisper API with language=ru
4. **GPT Response**: Send transcript to GPT-4o-mini with system prompt tailored for child-friendly, tactile descriptions
5. **TTS Playback**: Convert response to speech via OpenAI TTS (voice: "alloy"), play as MP3

### Key Technical Details

- **Audio Format Conversion**: Tap installed with native format, then converted to 16kHz mono for Whisper compatibility
- **Session Management**: AVAudioSession switches between `.record` (for listening) and `.playback` (for TTS)
- **Silence Detection**: Timer checks every 0.3s if speech activity stopped for 2+ seconds
- **API Integration**: All OpenAI APIs (Whisper, GPT, TTS) called directly via URLSession

## Important Configuration

### API Key Setup

The OpenAI API key is stored in `Maloy/Config.swift` (line 38 of ContentView.swift):
```swift
private let openAIKey = Config.openAIKey
```

**Security Architecture**:
- `Config.swift` contains the actual API key and is **excluded from git** via `.gitignore`
- `Config.swift.example` is a template committed to the repository
- New developers copy `Config.swift.example` → `Config.swift` and add their own key
- This prevents accidental exposure of API keys on GitHub

### Info.plist
Contains microphone permission description:
```xml
<key>NSMicrophoneUsageDescription</key>
<string>App uses the microphone to recognize your voice.</string>
```

### System Prompt
The assistant personality is defined in the `askGPT` method (lines 242-250). Key characteristics:
- Named "Малой" (Maloy)
- Speaks Russian with occasional English phrases
- Uses simple, friendly language appropriate for a 5th grader
- Provides tactile descriptions (shape, size, texture) for visual concepts
- Responds concisely (2-4 sentences typically)
- Can read books in chunks of 3-4 sentences

## Development Workflow

### Adding New Features

When adding features to this app:
1. Most logic resides in `AudioManager` class within `ContentView.swift`
2. UI updates are driven by `@Published` properties: `recognizedText`, `responseText`, `isListening`
3. Audio state changes require careful AVAudioSession category management
4. Consider the user is visually impaired - all feedback must be audio-based

### Testing

- **Physical Device Recommended**: Microphone recording and voice activity detection work better on real hardware
- **Test Permissions**: First launch requires microphone permission grant
- **Test Scenarios**:
  - Initial greeting and conversation start
  - Speech recognition in noisy vs. quiet environments
  - Silence detection triggering correctly after speech stops
  - TTS playback interrupting/resuming recording cycle

### Common Modifications

**Change TTS Voice**: Edit line 295 in `ContentView.swift`:
```swift
"voice": "alloy" // Options: alloy, echo, fable, onyx, nova, shimmer
```

**Adjust Silence Timeout**: Edit line 178:
```swift
if Date().timeIntervalSince(self.lastSpeechTime) > 2.0 // Change 2.0 to desired seconds
```

**Modify System Prompt**: Edit lines 242-250 to adjust assistant personality and behavior

**Change GPT Model**: Edit line 253:
```swift
"model": "gpt-4o-mini" // Can use gpt-4, gpt-3.5-turbo, etc.
```

## File Structure

```
Maloy/
├── .gitignore                    # Git ignore rules (excludes Config.swift)
├── CLAUDE.md                     # This file - AI assistant guidance
├── Maloy.xcodeproj/              # Xcode project file
│   └── project.pbxproj           # Project configuration
└── Maloy/                        # Source code
    ├── MaloyApp.swift            # App entry point
    ├── ContentView.swift         # Main view + AudioManager logic
    ├── Config.swift              # API keys (NOT in git - create from .example)
    ├── Config.swift.example      # Template for Config.swift
    ├── Info.plist                # App configuration (microphone permissions)
    └── Assets.xcassets/          # App icons and assets
```

## Known Limitations

- No conversation history - each GPT request is stateless
- No offline mode - requires internet for all AI features
- No error handling UI - errors only logged to console
- Single language support (Russian)
- API key stored in local file (consider using Keychain for production)
