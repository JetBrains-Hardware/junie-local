# Junie Local

Local inference support for Junie on macOS. This repository provides an automated installer that sets up the **junie-mlx-vlm** inference engine, downloads the **Qwen3.6-27B-4bit** model, registers it with Junie, and starts the engine in the background.

## System Requirements

- **macOS 15** or higher
- **Apple Silicon** processor (M4 or M5 recommended; older Apple Silicon works with a warning)
- **40 GB RAM** minimum (60 GB recommended for optimal performance)
- **~21 GB** free disk space (~15 GB models, ~0.5 GB engine)

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
- **Engine:** `junie-mlx-vlm` v0.1.1, unpacked under `~/.local/share/junie-local/versions/`.
- **Inference port:** `19239` — the port the engine serves on and the Junie model config points at.
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
{"event":"config","port":19239,"ram_gb":35,"engine_version":"0.1.1","checks_passed":true}
{"event":"step_start","id":"engine|models|configure|start","title":"..."}
{"event":"progress","file":"...","bytes":123,"total":456,"label":"..."}
{"event":"activity","action":"verifying|extracting","file":"...","label":"..."}
{"event":"step_done","id":"engine|models|configure|start"}
{"event":"warning","message":"..."}
{"event":"error","message":"..."}
{"event":"done","model_id":"...","port":19239,"model_path":"...","label":"..."}
```

The `hello` event is always first. `check` events describe the hard/soft requirement checks; `config` reports the settings the script will use and whether all hard requirements passed. Download `progress` is emitted roughly once per second with absolute byte counts (correct across resumed downloads). The `label` field on `progress` and `activity` names the artifact being processed ("inference engine", "Qwen 3.6 27B 4bit", "MTP draft model") for display. A successful install ends with `done`; a failed one ends with `error`.

Consumers must check the `protocol` version in `hello` and ignore unknown event types and fields — new event types and fields may be added without a protocol bump; the version only changes on incompatible changes to existing events. A typical embedding flow is: run `install.sh --check-only --json` to show requirements and the configuration that will be used, then run `install.sh --json` to install.

### Note on Terminal Behavior

When the script is run from Junie, the terminal window will close automatically when the script completes. The script displays a "press any key to exit" message at the end of every exit path to give you time to read the final output.

## What Gets Installed

| Component | Size | Destination |
|---|---|---|
| **junie-mlx-vlm 0.1.1** | ~180 MB (~470 MB unpacked) | `~/.local/share/junie-local/versions/0.1.1/` |
| **Qwen3.6-27B-4bit** | ~15 GB | `~/.local/share/junie-local/models/` |
| **Qwen3.6-27B-MTP-4bit** | ~247 MB | `~/.local/share/junie-local/models/` |

Every archive is downloaded, verified against its SHA256 checksum, and unpacked. A marker file records each completed unpack (`.models--<id>.installed` for models, `.<version>.installed` for the engine), so re-running the installer skips what is already in place.

Resulting layout:

```
~/.local/share/junie-local/
├── current -> versions/0.1.1
├── versions/0.1.1/
│   ├── junie-mlx-vlm          # the engine binary
│   ├── serverctl.sh           # start/stop/status control script
│   └── _internal/
├── models/
├── server-config.json         # written by the engine on first start
└── junie-mlx-vlm-daemon.log
```

## Inference Engine

**junie-mlx-vlm** serves an OpenAI-compatible API on port `19239` and supervises the inference worker itself. Engine releases are unpacked side by side under `versions/`, and `current` symlinks the one to run — so an upgrade is a new directory plus a symlink swap.

Each release includes `serverctl.sh`, a curl-based control script. The installer uses it to start and stop the engine:

```bash
~/.local/share/junie-local/current/serverctl.sh start
```

It is detached from the installer, so it keeps running after the script (and the terminal) exits. If an engine is already running, the installer gracefully stops it first with `serverctl.sh stop` (POST /shutdown) so the new version takes the port. After starting, the installer polls `/status` until the phase is `ready` — the model itself keeps loading in the background, so the first request through Junie has to wait for it.

The engine reads its settings from `server-config.json` (or `$JUNIE_SERVER_CONFIG`), which it creates itself on first start. It needs the models to be in place before it can serve, which is why the installer downloads them first.

`serverctl.sh` supports these commands:

```bash
~/.local/share/junie-local/current/serverctl.sh start     # launch the server
~/.local/share/junie-local/current/serverctl.sh stop      # graceful shutdown
~/.local/share/junie-local/current/serverctl.sh status    # lifecycle phase + inference progress
~/.local/share/junie-local/current/serverctl.sh wait      # poll until phase is "ready"
~/.local/share/junie-local/current/serverctl.sh health    # health check
~/.local/share/junie-local/current/serverctl.sh settings  # current serving settings
~/.local/share/junie-local/current/serverctl.sh apply key=value   # apply settings at runtime
```

## Junie Model Configuration

The installer creates a Junie model config at `~/.junie/models/local-qwen3.6-27b-4bit.json` pointing at `http://localhost:19239/v1/chat/completions` (no API key), with the model id the engine serves (`mlx-community/Qwen3.6-27B-4bit`), and sets it as the default Junie model. Restart Junie to apply the change; you can switch models later with the `/models` command.

## Resumable Downloads with Automatic Retries

Downloads are stored in `~/.local/share/junie-local/incomplete_downloads/`. If a download fails due to a network issue, the script automatically retries up to **3 times** with exponential backoff (starting at 2 seconds, doubling each attempt). Partial downloads are preserved and resumed using `curl -C -`.

If the script is interrupted (Ctrl+C, etc.), the partial downloads remain. Simply re-run the script and it will resume from where it left off.

Once all downloads are verified and extracted, the `incomplete_downloads` directory is automatically removed.