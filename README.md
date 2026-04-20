# LocalLLMChat

A Flutter chat app for privately talking to locally-hosted LLMs through any OpenAI-compatible API (llama.cpp, Ollama, LM Studio, vLLM, …).  
Primary target is Android; the adaptive layout also runs on Windows and Linux.

---

## Features

| Category | What it does |
|---|---|
| **Chat** | Streaming responses, Markdown rendering, selectable text, collapsible thinking blocks (Qwen3 / reasoning models) |
| **Multi-conversation** | Permanent sidebar on wide screens, drawer on mobile; named conversations with long-press context menu |
| **MCP tools** | Multiple MCP servers (Streamable-HTTP and HTTP+SSE transports, auto-detected); per-server Home/Away URLs; agentic tool loop with live tool-call and result cards |
| **Dual URL** | Home URL (local Wi-Fi) + Away URL (WireGuard / Tailscale); auto-detects which is reachable |
| **Secret chats** | Password-protected conversations hidden until unlocked; SHA-256 hashed PIN |
| **Backup & Restore** | Export all chats + settings to a JSON file; AES-256-GCM encrypted (PBKDF2-SHA256) when a secret-chat password is set |
| **Appearance** | Per-chat and global background colour, user bubble colour, AI bubble colour |
| **Generation** | Configurable temperature, max tokens (128 – 262 144), request timeout, system prompt |

---

## Architecture

```
lib/
├── main.dart
├── models/
│   ├── conversation.dart      – Conversation + message list, colour overrides
│   ├── mcp_server.dart        – McpServer model (id, URLs, transport, enabled)
│   ├── message.dart           – Role enum, tool-call fields, contentForApi
│   ├── settings.dart          – AppSettings (URLs, model, MCP servers, colours, …)
│   └── tool_call.dart         – McpToolDef, ToolCall, McpContent, LlmResponse
├── providers/
│   └── app_provider.dart      – ChangeNotifier; streaming, agentic loop, backup
├── services/
│   ├── api_service.dart       – OpenAI-compatible HTTP client (SSE streaming + tools)
│   ├── backup_crypto.dart     – AES-256-GCM backup encryption (PBKDF2-SHA256)
│   ├── base_mcp_service.dart  – Abstract MCP service interface
│   ├── mcp_service.dart       – MCP Streamable-HTTP transport
│   ├── mcp_sse_service.dart   – MCP HTTP+SSE transport (legacy servers)
│   ├── storage_service.dart   – SharedPreferences JSON persistence
│   └── streaming_keep_alive.dart – Android foreground service during streaming
├── screens/
│   ├── chat_screen.dart       – Adaptive layout: permanent sidebar ≥720 px, drawer below
│   ├── mcp_servers_screen.dart– Per-server config (URLs, transport, tool list)
│   └── settings_screen.dart   – Connection, model, MCP, appearance, privacy, backup
└── widgets/
    ├── chat_input.dart        – Text field; Enter sends on desktop, Shift+Enter newline
    ├── color_picker.dart      – Colour palette dialog
    ├── message_bubble.dart    – User / assistant bubble with thinking-block support
    └── tool_bubble.dart       – Collapsible tool-call and tool-result cards
```

---

## Setup

### Prerequisites
- Flutter 3.10+ / Dart 3+
- An OpenAI-compatible inference server on your network:
  - [llama.cpp server](https://github.com/ggerganov/llama.cpp/tree/master/examples/server)
  - [Ollama](https://ollama.ai) (`OLLAMA_HOST=0.0.0.0`)
  - [LM Studio](https://lmstudio.ai) (local server mode)
  - [vLLM](https://github.com/vllm-project/vllm)

### Android (release APK)

```bash
git clone git@hacksaar.de:Mathew3000/localllmchat.git
cd localllmchat
flutter pub get
flutter build apk --release
# → build/app/outputs/flutter-apk/app-release.apk
```

Install with `adb install -r` to preserve existing app data between updates.

### Windows (local build)

> **Requires:** [Developer Mode](ms-settings:developers) enabled (Flutter needs symlink support for plugin builds).

```bat
build_windows.bat              :: build with current version
build_windows.bat 1.4.0        :: stamp version + build
```

Output: `build\windows\x64\runner\Release\`  
Distribute the entire folder — the `.exe` depends on the DLLs and `data\` directory alongside it.

### Linux (local build)

```bash
chmod +x build_linux.sh
./build_linux.sh               # build with current version
./build_linux.sh 1.4.0         # stamp version + build + package as .tar.gz
```

Output: `build/linux/x64/release/bundle/`  
When a version argument is given, a `build/LocalLLMChat-v1.4.0-linux.tar.gz` archive is also created.

---

## First launch

1. Open **Settings** (gear icon)
2. Set **Home URL** → your LLM server, e.g. `http://192.168.1.100:5000/v1`
3. Optionally set **Away URL** for remote access via WireGuard / Tailscale
4. Tap **Fetch** next to the model selector and choose a model
5. Save — start chatting

---

## MCP tools (optional)

1. Run an MCP-compatible tool server (e.g. [Local-MCP-server](https://github.com/BigStationW/Local-MCP-server))
2. Settings → **MCP Tools** → add a server (name + Home URL)
3. Each server supports an optional Away URL and a transport selector (**Auto** / **HTTP** / **SSE**)  
   — Auto tries Streamable-HTTP first and falls back to SSE automatically
4. Tap the tool count chip to see available tool names
5. The app runs an agentic loop automatically when MCP tools are loaded

---

## Remote access (Away URL)

When an Away URL is configured the app pings the Home URL before each request.  
If unreachable (1.5 s timeout) it switches to the Away URL automatically.  
A router/home icon in the toolbar turns coloured when the away URL is active — tap to force a re-check.

---

## Secret chats

1. Settings → **Privacy** → Set password
2. Long-press a conversation → **Move to secret chats**
3. Secret conversations are hidden until you long-press the sidebar header and enter your password

Passwords are stored as a SHA-256 hash — the plaintext never touches disk.

---

## Backup & Restore

Settings → **Backup & Restore**

- **Export** saves a `.json` file to any location via the system file picker  
  If a secret-chat password is set the file is AES-256-GCM encrypted (PBKDF2-SHA256, 100 000 iterations) — the password is required to restore it
- **Import** detects encrypted files automatically, prompts for the password, then replaces all conversations and settings after a confirmation step

---

## Dependencies

| Package | Purpose |
|---|---|
| `provider` | State management |
| `http` | HTTP client |
| `shared_preferences` | Local persistence |
| `crypto` | SHA-256 for secret-chat password hashing |
| `cryptography` | AES-256-GCM + PBKDF2-SHA256 for backup encryption |
| `file_picker` | SAF-based file save / load (backup export & import) |
| `flutter_markdown` | Markdown rendering in chat bubbles |
| `uuid` | Conversation / server IDs |
| `intl` | Date formatting |

---

## License

MIT — do whatever you want, attribution appreciated.
