# LocalLLMChat

A Flutter chat app for privately talking to locally-hosted LLMs through any OpenAI-compatible API (llama.cpp, Ollama, LM Studio, vLLM, …).  
Built for Android; compiles for iOS/desktop with no code changes.

---

## Features

| Category | What it does |
|---|---|
| **Chat** | Streaming responses with a typing indicator, Markdown rendering, selectable text |
| **Multi-conversation** | Sidebar with named conversations, long-press context menu |
| **MCP tools** | Connects to a [Local-MCP-server](https://github.com/BigStationW/Local-MCP-server), forwards tools to the LLM, runs an agentic loop, displays collapsible tool-call / tool-result cards |
| **Dual URL** | Home URL (local Wi-Fi) + Away URL (WireGuard / Tailscale); app auto-detects which is reachable |
| **Secret chats** | Password-protected conversations hidden behind SHA-256 hashed PIN |
| **Appearance** | Per-chat and global background colour, user bubble colour, AI bubble colour |
| **Generation** | Configurable temperature, max tokens (128 – 262 144), system prompt |

---

## Architecture

```
lib/
├── main.dart
├── models/
│   ├── conversation.dart   – Conversation + message list, colour overrides
│   ├── message.dart        – Role enum (user/assistant/tool), tool-call fields
│   ├── settings.dart       – AppSettings (URLs, model, MCP, colours, …)
│   └── tool_call.dart      – McpToolDef, ToolCall, McpContent, LlmResponse
├── providers/
│   └── app_provider.dart   – State management (ChangeNotifier); streaming + agentic loop
├── services/
│   ├── api_service.dart    – OpenAI-compatible HTTP client (streaming + tool calls)
│   ├── mcp_service.dart    – MCP Streamable-HTTP client (session handshake, tools/list, tools/call)
│   ├── storage_service.dart– SharedPreferences JSON persistence
│   └── streaming_keep_alive.dart – Wakelock during streaming
├── screens/
│   ├── chat_screen.dart    – Main UI: sidebar, message list, input bar
│   └── settings_screen.dart– All settings (connection, model, MCP, appearance, privacy)
└── widgets/
    ├── message_bubble.dart – User / assistant bubble with custom colour support
    ├── tool_bubble.dart    – Collapsible tool-call and tool-result cards
    ├── chat_input.dart     – Text field + send / cancel button
    └── color_picker.dart   – Colour palette dialog
```

---

## Setup

### Prerequisites
- Flutter 3.10+ / Dart 3+
- An OpenAI-compatible inference server running somewhere on your network
  - [llama.cpp server](https://github.com/ggerganov/llama.cpp/tree/master/examples/server)
  - [Ollama](https://ollama.ai) (`OLLAMA_HOST=0.0.0.0`)
  - [LM Studio](https://lmstudio.ai) (local server mode)
  - [vLLM](https://github.com/vllm-project/vllm)

### Build & run

```bash
# Clone
git clone git@hacksaar.de:Mathew3000/localllmchat.git
cd localllmchat

# Install dependencies
flutter pub get

# Run on a connected Android device
flutter run --release

# Build a release APK
flutter build apk --release
# → build/app/outputs/flutter-apk/app-release.apk
```

### First launch
1. Open **Settings** (gear icon)
2. Set **Home URL** to your LLM server, e.g. `http://192.168.1.100:5000/v1`
3. Optionally set **Away URL** for remote access via WireGuard/Tailscale
4. Tap **Fetch** next to the model selector
5. Save — start chatting

### MCP tools (optional)
1. Run [Local-MCP-server](https://github.com/BigStationW/Local-MCP-server) on your machine
2. In Settings → **MCP Tools**, enable the toggle and enter the server URL (e.g. `http://192.168.1.100:4242`)
3. Tap **Fetch tools** — confirmed tools will show a count
4. The app automatically switches to an agentic loop when MCP is active

---

## Remote access (Away URL)

When **Away URL** is set the app pings the Home URL on every send.  
If unreachable (timeout 1.5 s) it falls back to the Away URL automatically.  
A router/home icon in the app bar turns coloured when the away URL is active.  
Tap it to force a re-check.

---

## Secret chats

1. Settings → **Privacy** → Set password
2. Long-press any conversation → **Make secret**
3. Secret conversations vanish until you unlock from the sidebar lock icon

Passwords are stored as a SHA-256 hash — the plaintext never touches disk.

---

## Dependencies

| Package | Purpose |
|---|---|
| `provider` | State management |
| `http` | HTTP client |
| `shared_preferences` | Local persistence |
| `crypto` | SHA-256 for secret chat password |
| `flutter_markdown` | Markdown rendering in chat bubbles |
| `uuid` | Conversation / message IDs |

---

## License

MIT — do whatever you want, attribution appreciated.
