# Clicktion

A privacy-first macOS menu bar app that turns any screenshot into an LLM-powered action. Capture your screen, pick a *skill* (a small markdown prompt template like "Explain Error" or "Summarize"), and the LLM analyses what's on the screen. Private captures stay on local models by default; remote providers are only used when you opt in.

---

## Requirements

| Tool | Version |
|------|---------|
| macOS | 14 (Sonoma) or later |
| Swift | 6.1+ (command line tools) |
| Go | 1.22+ |
| CGO | enabled (for SQLite) |

---

## Quick start

```bash
git clone <repo> Clicktion && cd Clicktion
make dev
```

`make dev` builds both binaries, assembles and signs the app bundle, installs the Go service and default skills into `~/Library/Application Support/Clicktion/`, and launches the app.

On first launch a setup wizard walks you through:
1. Granting **screen recording** access (required)
2. Triggering the **local network** permission prompt
3. Adding your first **LLM model**
4. Running a **connection test**

---

## How it works

```
[Menu bar icon] → Capture → [Capture dialog]
                              ├ thumbnail + OCR preview (first 5 sentences)
                              ├ skill list on the right (click to run)
                              └ Image+Text / Image / Text picker
                                            │
                                            ▼
                            [Chat window streams the response]
                              ├ change skill (auto-restarts)
                              └ back arrow → re-edit capture
```

### Capture dialog

| Area | Description |
|------|-------------|
| **Toolbar (top)** | Title + buttons: Capture (new screenshot), Select region, Draw, Undo |
| **Thumbnail** | Preview of the screenshot (or cropped region). Copy-image button in the sidebar |
| **Text Captures** | OCR preview (first 5 sentences). Full text is still sent to the LLM. Copy button beside |
| **Mode picker** | Image + Text · Image only · Text only — controls what gets sent |
| **Skills (right)** | One-click skill list. The suggested skill (auto-picked from OCR triggers) is highlighted |

Clicking a skill is the action: the capture is submitted with that skill and the chat window opens to stream the response.

### Chat window

| Element | Description |
|---------|-------------|
| **Back arrow** (⌘[) | Closes the chat and reopens the capture dialog with the same image |
| **Skill picker** | Switch skill mid-conversation; clears chat history and re-runs with the new prompt |
| **Streaming response** | SSE-driven, token by token. Code blocks have a Copy button |
| **Follow-up field** | Auto-focused; ⌘↩ to send |

---

## Adding an LLM model

Clicktion works with any OpenAI-compatible endpoint. Open **Manage Models…** from the menu bar icon to add models via the web admin UI at `http://localhost:8080/admin/models`.

| Provider | Base URL | API key |
|----------|----------|---------|
| Ollama (local) | `http://localhost:11434/v1` | *(empty)* |
| LM Studio (local) | `http://localhost:1234/v1` | *(empty)* |
| Ollama on LAN | `http://192.168.x.x:11434/v1` | *(empty)* |
| OpenAI | `https://api.openai.com/v1` | `sk-…` |
| OpenRouter | `https://openrouter.ai/api/v1` | `sk-or-…` |

**Privacy note:** Endpoints at RFC1918 addresses or `localhost` are classified as **local** automatically. Private captures (the default) can only be processed by local models. The service enforces this — it's not just a UI hint.

---

## Settings

Open **Settings…** from the menu bar icon to configure app-wide defaults. Three tabs:

### General

| Setting | Description |
|---------|-------------|
| **Default model** | Used for every capture unless overridden. Fetched live from the Go service |
| **Capture disk usage** | Stepper, default **250 MB**. After every capture the service prunes oldest screenshots; captures with OCR text keep their chat thread (image only deleted), captures without OCR are removed entirely |
| **Response language** | The AI will always reply in the selected language. Defaults to system locale; appended to every skill prompt as `- You need to reply in <language>.` |

### Privacy

| Mode | Description |
|------|-------------|
| **Private only — local LLMs** | Every capture stays on your network. Only models at `localhost` or RFC1918 addresses are used |
| **Trust my LLM provider** | Captures can be sent to any configured model |

### Profiles

Two master profiles drive LLM behaviour. The active profile is chosen per capture via the input-mode picker / chat picker:

| Profile | Default |
|---------|---------|
| **Thinking** | Reasoning enabled, model defaults for temperature & max tokens, light "think before answering" prompt |
| **Direct** | Reasoning off, temperature 0.3, 2048 max tokens, "be concise, no preamble" prompt |

Each profile exposes a master system prompt (prepended before the skill prompt), temperature slider, max tokens, and a thinking toggle. **Reset to defaults** restores factory values.

---

## Skills

Skills define how the LLM responds to a capture. Each skill is two files in `~/Library/Application Support/Clicktion/skills/`:

**`skill-name.md`** — frontmatter + system prompt:
```markdown
---
name: Explain Error
icon: exclamationmark.triangle
triggers: error, exception, crash, stack trace
input_mode: image_and_text
---

You are analyzing a screenshot containing an error message…
```

**`skill-name.json`** — permission config (mostly defaults):
```json
{
  "allow_cli": false,
  "allow_file_write": false,
  "allow_network": false,
  "skip_confirmation": false,
  "blocklist": []
}
```

Edit skills from the menu bar: **Edit Skills…** opens a split-view editor. Drag rows to reorder — the order is persisted and shown in the capture dialog's skill list.

Default skills shipped: Explain Error, Generate Email Reply, Todo, Summarize, Write Documentation, Run CLI Command, Translate, Form Fill Assistant, Code Review, Extract & Structure Data.

---

## Project structure

```
Clicktion/
├── Sources/Clicktion/          # Swift macOS app
│   ├── App/                    # AppDelegate, AppState, ServiceManager, StatusBarIcon
│   ├── Capture/                # ScreenCaptureKit, OCR, capture dialog
│   ├── LLM/                    # ServiceClient (HTTP+SSE), ModelConfig
│   ├── Settings/               # SettingsView, SettingsWindow
│   ├── Skills/                 # Skill model, loader (custom order), editor
│   └── UI/                     # Menu, chat window, message bubble, setup wizard
├── clicktion-service/          # Go backend service
│   ├── cmd/server/             # main.go
│   ├── internal/
│   │   ├── api/                # HTTP handlers, router, SSE streaming, prune
│   │   ├── db/                 # SQLite (captures, jobs, models, auth, llm logs)
│   │   └── llm/                # OpenAI-compatible client, skill pre-selection
│   ├── web/
│   │   ├── templates/          # Go html/template pages (archive + admin)
│   │   └── static/             # CSS
│   └── vendor/                 # Vendored SQLite (CGo, mattn/go-sqlite3)
├── skills/                     # Default skill definitions (.md + .json pairs)
├── Clicktion.app/              # App bundle (binary excluded from git)
├── Clicktion.entitlements      # Screen capture + network entitlements
├── Package.swift               # Swift package definition
└── Makefile                    # Build targets
```

---

## Development workflow

```bash
make dev            # full rebuild + reinstall + relaunch (use after any change)
make go-build       # rebuild Go service only
make swift-build    # rebuild Swift app only (debug)
make swift-release  # rebuild Swift app (release, used by make dev)
make install-skills # reinstall default skills from skills/
```

After `make dev` the app relaunches automatically. The service is killed and respawned cleanly to pick up the new binary (avoids the macOS amfid issue where overwriting an executable in place rejects the new binary).

---

## Web interfaces

With the app running, open these in any browser:

| URL | Description |
|-----|-------------|
| `http://localhost:8080/archive` | Browse all captures, search OCR text, view chat threads |
| `http://localhost:8080/admin` | Dashboard — LLM usage, model stats |
| `http://localhost:8080/admin/models` | Add / edit / test / delete LLM models |
| `http://localhost:8080/admin/keys` | Manage API keys (only relevant if you expose the service beyond localhost) |
| `http://localhost:8080/admin/storage` | Storage stats and manual bulk cleanup |

---

## API

The Mac app talks to the Go service over HTTP. All `/api/` routes require `Authorization: Bearer <key>`. The Mac app's key is auto-generated on first launch via `POST /bootstrap` and stored at `~/Library/Application Support/Clicktion/.apikey`.

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/bootstrap` | Create first API key (no auth; locked after first use) |
| `GET`  | `/health` | Liveness check |
| `POST` | `/api/captures` | Submit a capture (image + OCR + skills), returns suggested skill |
| `POST` | `/api/jobs` | Start LLM execution; supports `send_image`, `send_ocr`, `master_prompt`, `temperature`, `max_tokens`, `thinking_enabled`, `fresh` |
| `GET`  | `/api/jobs/{id}/stream` | SSE stream of LLM tokens (reasoning tokens prefixed with `\x01`) |
| `POST` | `/api/jobs/{id}/messages` | Send a follow-up message, re-triggers streaming |
| `GET`  | `/api/models` | List configured models |
| `POST` | `/api/models` | Add a model |
| `PUT`  | `/api/models/{id}` | Update a model |
| `DELETE` | `/api/models/{id}` | Delete a model |
| `POST` | `/api/models/{id}/test` | Test a model with a live request |
| `POST` | `/api/models/{id}/setdefault` | Mark a model as default |
| `POST` | `/api/storage/prune` | Trim captures dir to `max_bytes`, deleting oldest first |
| `GET`  | `/api/auth/keys` | List API keys |
| `POST` | `/api/auth/keys` | Create an API key |
| `DELETE` | `/api/auth/keys/{id}` | Delete an API key |

---

## Data storage

Everything lives in `~/Library/Application Support/Clicktion/`:

```
Clicktion/
├── clicktion-service   # Go binary (installed by make dev)
├── clicktion.db        # SQLite database
├── captures/           # Screenshot PNG files (auto-pruned)
├── skills/             # Skill .md and .json files
└── .apikey             # Plain-text bearer key for the local service
```

SQLite holds captures, chat threads, LLM call logs, model configs, and API keys. Screenshots live on disk, referenced by path.

---

## Privacy

- **Default: private.** Every capture is marked private unless explicitly toggled to public.
- **Local-only enforcement.** Private captures are blocked from being sent to non-local LLM endpoints at the **service** layer, not just the UI.
- **No telemetry.** Nothing leaves your machine unless you configure a remote LLM and explicitly mark a capture as public.
- **OCR runs on-device** via Apple's Vision framework — no third-party text recognition.

---

## License

Source available under the [**PolyForm Noncommercial License 1.0.0**](LICENSE).

- ✅ Free to read, fork, modify, and run for **non-commercial** purposes — personal use, study, hobby projects, charities, schools, research.
- ❌ Commercial use (including reselling on the App Store or any other marketplace) requires a separate license from the copyright holder.
- The official build distributed on the Mac App Store is sold under a separate commercial license held by the copyright holder.

If you'd like to use Clicktion commercially, get in touch.
