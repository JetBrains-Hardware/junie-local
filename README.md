# Junie Local

Local inference support for Junie on macOS. This repository provides an automated installer that sets up **oMLX** and downloads the **Qwen3.6-27B-4bit** model so you can run AI locally on your Mac.

## System Requirements

- **macOS 26** or higher
- **Apple Silicon** processor (M4 or M5 recommended; older Apple Silicon works with a warning)
- **40 GB RAM** minimum (60 GB recommended for optimal performance)
- **~65 GB** free disk space (~15 GB for models, up to 50 GB for the SSD cache)

## Quick Install

### Running from Junie

The installer is designed to be run with `sh` from within Junie. No parameters are passed from Junie — all user interaction and logic is handled inside the script itself.

### Running Manually

The installer is interactive (it asks for confirmation and lets you customize the port and RAM allowance), so it needs a terminal. Download it first, then run it:

```bash
curl -fsSL https://raw.githubusercontent.com/erokhins/junie-local/refs/heads/main/install.sh -o /tmp/junie-local-install.sh && sh /tmp/junie-local-install.sh
```

#### Memory Parameter

By default, the script allocates **35 GB** of RAM to oMLX. You can adjust this by passing the desired value as the first argument:

```bash
curl -fsSL https://raw.githubusercontent.com/erokhins/junie-local/refs/heads/main/install.sh -o /tmp/junie-local-install.sh && sh /tmp/junie-local-install.sh 48
```

This allocates 48 GB to oMLX (17 GB for the model, the rest for hot/SSD caches). You can also change the value interactively by answering `n` at the confirmation prompt.

### Command-Line Options

```
sh install.sh [RAM_GB] [options]
  --ram N       RAM allowance in GB for inference (default: 35, min 18); same as the positional argument
  --port N      Port for a fresh oMLX install (default: first free port in 8000-8999; ignored if oMLX is already installed)
  --yes, -y     Skip the confirmation prompt
  --check-only  Report system information and install configuration, then exit (exit code 0 if all hard requirements are met, 1 otherwise)
  --json        Emit machine-readable events on stdout, human output on stderr (implies --yes)
  --help, -h    Show this help
```

### Machine-Readable Mode (`--json`)

`--json` exists so that UIs (such as Junie's built-in installer screen) can embed the script and render its progress natively while this script remains the single source of truth for all install logic. In this mode:

- stdout carries exactly one JSON event per line; all human-oriented output goes to stderr.
- No prompts are shown: the confirmation is skipped and no "press any key" pause happens on exit.
- Configuration is passed via `--ram`/`--port` instead of interactive customization.

Events:

```
{"event":"hello","protocol":1}
{"event":"check","name":"os|cpu|ram|omlx","status":"ok|warn|fail","value":"...","requirement":"..."}
{"event":"config","port":8000,"ram_gb":35,"omlx_installed":false,"omlx_version":"","checks_passed":true}
{"event":"step_start","id":"omlx|models|configure","title":"..."}
{"event":"progress","file":"...","bytes":123,"total":456,"label":"..."}
{"event":"activity","action":"verifying|extracting","file":"...","label":"..."}
{"event":"step_done","id":"omlx|models|configure"}
{"event":"warning","message":"..."}
{"event":"error","message":"..."}
{"event":"done","model_id":"...","port":8000}
```

The `hello` event is always first. `check` events describe the hard/soft requirement checks; `config` reports the effective settings and whether all hard requirements passed. Download `progress` is emitted roughly once per second with absolute byte counts (correct across resumed downloads). The `label` field on `progress` and `activity` names the artifact being processed ("oMLX server", "Local Qwen 3.6 27B 4bit", "MTP draft model") for display. A successful install ends with `done`; a failed one ends with `error`.

Consumers must check the `protocol` version in `hello` and ignore unknown event types and fields — new event types and fields may be added without a protocol bump; the version only changes on incompatible changes to existing events. A typical embedding flow is: run `install.sh --check-only --json` to show requirements and defaults, collect settings in the UI, then run `install.sh --json --ram N [--port N]`.

### Note on Terminal Behavior

When the script is run from Junie, the terminal window will close automatically when the script completes. The script displays a "press any key to exit" message at the end of every exit path to give you time to read the final output.

## What Gets Installed

| Component | Size | Destination |
|---|---|---|
| **oMLX 0.5.3** | ~50 MB (DMG) | `~/Applications/oMLX.app` |
| **Qwen3.6-27B-4bit** | ~15 GB | `~/.local/share/junie-local/models/` |
| **Qwen3.6-27B-MTP-4bit** | ~247 MB | `~/.local/share/junie-local/models/` |

The models are extracted into `~/.local/share/junie-local/models/` and registered with oMLX automatically.

## oMLX

The installer downloads and configures **[oMLX](https://omlx.ai)** — a local ML inference engine for Apple Silicon. oMLX manages model loading, caching, and serves an OpenAI-compatible API that Junie connects to.

- **Website:** [omlx.ai](https://omlx.ai)
- **GitHub Releases:** [jundot/omlx](https://github.com/jundot/omlx/releases)

If oMLX is already installed (in `/Applications` or `~/Applications`), the installer reuses it and its configured port. Version **0.5.2** or higher is required — if your installation is older, the installer exits and asks you to update oMLX manually before re-running.

After installation, oMLX is configured with:
- **SSD cache:** 50 GB
- **Hot cache:** RAM allocation minus 17 GB (reserved for the model)
- **Custom model settings** optimized for Qwen3.6-27B-4bit with MTP (Multi-Token Prediction) support

## Junie Model Configuration

The installer creates a Junie model config at `~/.junie/models/local-qwen3.6-27b-4bit.json` pointing to the local oMLX server, and sets it as the default Junie model. Restart Junie to apply the change; you can switch models later with the `/models` command.

## Resumable Downloads with Automatic Retries

Downloads are stored in `~/.local/share/junie-local/incomplete_downloads/`. If a download fails due to a network issue, the script automatically retries up to **3 times** with exponential backoff (starting at 2 seconds, doubling each attempt). Partial downloads are preserved and resumed using `curl -C -`.

If the script is interrupted (Ctrl+C, etc.), the partial downloads remain. Simply re-run the script and it will resume from where it left off.

Once all downloads are verified and extracted, the `incomplete_downloads` directory is automatically removed.