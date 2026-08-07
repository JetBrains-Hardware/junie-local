# Junie Local

Local inference support for Junie on macOS. This repository provides an automated installer that downloads the **Qwen3.6-27B-4bit** model and registers it with Junie so you can run AI locally on your Mac.

> **Note:** the installer does not install an inference engine yet — the previous oMLX integration has been removed and its replacement is not wired up. The downloaded model stays unavailable to Junie until a server answers on port `19239`.

## System Requirements

- **macOS 26** or higher
- **Apple Silicon** processor (M4 or M5 recommended; older Apple Silicon works with a warning)
- **40 GB RAM** minimum (60 GB recommended for optimal performance)
- **~20 GB** free disk space for the models

## Quick Install

### Running from Junie

The installer is designed to be run with `sh` from within Junie. No parameters are passed from Junie — all install logic is handled inside the script itself.

### Running Manually

The installer is non-interactive and takes no configuration: it always uses its built-in defaults. Download it first, then run it:

```bash
curl -fsSL https://raw.githubusercontent.com/erokhins/junie-local/refs/heads/main/install.sh -o /tmp/junie-local-install.sh && sh /tmp/junie-local-install.sh
```

#### Defaults

- **Models directory:** `~/.local/share/junie-local/models`
- **Inference port:** `19239` — the port the Junie model config points at.
- **RAM allowance:** 35 GB the inference engine may spend on weights and KV cache. Reported in the `config` event; not consumed by the installer itself.

### Command-Line Options

```
sh install.sh [options]
  --check-only  Report system information and install configuration, then exit (exit code 0 if all hard requirements are met, 1 otherwise)
  --json        Emit machine-readable events on stdout, human output on stderr
  --help, -h    Show this help
```

### Machine-Readable Mode (`--json`)

`--json` exists so that UIs (such as Junie's built-in installer screen) can embed the script and render its progress natively while this script remains the single source of truth for all install logic. In this mode:

- stdout carries exactly one JSON event per line; all human-oriented output goes to stderr.
- No "press any key" pause happens on exit.

Events:

```
{"event":"hello","protocol":1}
{"event":"check","name":"os|cpu|ram","status":"ok|warn|fail","value":"...","requirement":"..."}
{"event":"config","port":19239,"ram_gb":35,"checks_passed":true}
{"event":"step_start","id":"models|configure","title":"..."}
{"event":"progress","file":"...","bytes":123,"total":456,"label":"..."}
{"event":"activity","action":"verifying|extracting","file":"...","label":"..."}
{"event":"step_done","id":"models|configure"}
{"event":"warning","message":"..."}
{"event":"error","message":"..."}
{"event":"done","model_id":"...","port":19239}
```

The `hello` event is always first. `check` events describe the hard/soft requirement checks; `config` reports the settings the script will use and whether all hard requirements passed. Download `progress` is emitted roughly once per second with absolute byte counts (correct across resumed downloads). The `label` field on `progress` and `activity` names the artifact being processed ("Local Qwen 3.6 27B 4bit", "MTP draft model") for display. A successful install ends with `done`; a failed one ends with `error`.

Consumers must check the `protocol` version in `hello` and ignore unknown event types and fields — new event types and fields may be added without a protocol bump; the version only changes on incompatible changes to existing events. A typical embedding flow is: run `install.sh --check-only --json` to show requirements and the configuration that will be used, then run `install.sh --json` to install.

### Note on Terminal Behavior

When the script is run from Junie, the terminal window will close automatically when the script completes. The script displays a "press any key to exit" message at the end of every exit path to give you time to read the final output.

## What Gets Installed

| Component | Size | Destination |
|---|---|---|
| **Qwen3.6-27B-4bit** | ~15 GB | `~/.local/share/junie-local/models/` |
| **Qwen3.6-27B-MTP-4bit** | ~247 MB | `~/.local/share/junie-local/models/` |

Each archive is downloaded, verified against its SHA256 checksum, and extracted into `~/.local/share/junie-local/models/`. A marker file (`.models--<id>.installed`) records a completed extraction, so re-running the installer skips models that are already in place.

## Inference Engine

None is installed. The engine that serves the model over an OpenAI-compatible API is expected to listen on port `19239` (`ENGINE_PORT` in `install.sh`) — that is the only contract between it and the Junie model config this script writes.

## Junie Model Configuration

The installer creates a Junie model config at `~/.junie/models/local-qwen3.6-27b-4bit.json` pointing at `http://localhost:19239/v1/chat/completions` (no API key), and sets it as the default Junie model. Restart Junie to apply the change; you can switch models later with the `/models` command.

## Resumable Downloads with Automatic Retries

Downloads are stored in `~/.local/share/junie-local/incomplete_downloads/`. If a download fails due to a network issue, the script automatically retries up to **3 times** with exponential backoff (starting at 2 seconds, doubling each attempt). Partial downloads are preserved and resumed using `curl -C -`.

If the script is interrupted (Ctrl+C, etc.), the partial downloads remain. Simply re-run the script and it will resume from where it left off.

Once all downloads are verified and extracted, the `incomplete_downloads` directory is automatically removed.