# Junie Local

Local inference support for Junie on macOS. This repository provides an automated installer that sets up **oMLX** and downloads the **Qwen3.6-27B-4bit** model so you can run AI locally on your Mac.

## System Requirements

- **macOS 26** or higher
- **Apple M4 or M5** processor (recommended; other CPUs may work with a warning)
- **32 GB RAM** minimum (63 GB recommended for optimal performance)
- **~40 GB** free disk space for models and caches

## Quick Install

### Running from Junie

The installer is designed to be run with `sh` from within Junie. No parameters are passed from Junie — all user interaction and logic is handled inside the script itself.

### Running Manually

You can also run the installer directly from your terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/erokhins/junie-local/refs/heads/main/install.sh | zsh
```

#### Memory Parameter

By default, the script allocates **35 GB** of RAM to oMLX. You can adjust this by passing the desired value as the first argument:

```bash
curl -fsSL https://raw.githubusercontent.com/erokhins/junie-local/refs/heads/main/install.sh | zsh - 48
```

This allocates 48 GB to oMLX (17 GB for the model, the rest for hot/SSD caches).

### Note on Terminal Behavior

When the script is run from Junie, the terminal window will close automatically when the script completes. The script displays a "press any key to exit" message at the end of every exit path to give you time to read the final output.

## What Gets Installed

| Component | Size | Destination |
|---|---|---|
| **oMLX 0.5.3** | ~50 MB (DMG) | `/Applications/oMLX.app` |
| **Qwen3.6-27B-4bit** | ~15 GB | `~/.local/share/junie-local/models/` |
| **Qwen3.6-27B-MTP-4bit** | ~247 MB | `~/.local/share/junie-local/models/` |

The models are extracted into `~/.local/share/junie-local/models/` and registered with oMLX automatically.

## oMLX

The installer downloads and configures **[oMLX](https://omlx.ai)** — a local ML inference engine for Apple Silicon. oMLX manages model loading, caching, and serves an OpenAI-compatible API that Junie connects to.

- **Website:** [omlx.ai](https://omlx.ai)
- **GitHub Releases:** [jundot/omlx](https://github.com/jundot/omlx/releases)

After installation, oMLX is configured with:
- **SSD cache:** 50 GB
- **Hot cache:** RAM allocation minus 17 GB (reserved for the model)
- **Custom model settings** optimized for Qwen3.6-27B-4bit with MTP (Multi-Token Prediction) support

## Junie Model Configuration

The installer creates a Junie model config at `~/.junie/models/local-qwen3.6-27b-4bit.json` pointing to the local oMLX server. After installation, select it in Junie with the `/models` command.

## Resumable Downloads with Automatic Retries

Downloads are stored in `~/.local/share/junie-local/incomplete_downloads/`. If a download fails due to a network issue, the script automatically retries up to **5 times** with exponential backoff (starting at 2 seconds, doubling each attempt). Partial downloads are preserved and resumed using `curl -C -`.

If the script is interrupted (Ctrl+C, etc.), the partial downloads remain. Simply re-run the script and it will resume from where it left off.

Once all downloads are verified and extracted, the `incomplete_downloads` directory is automatically removed.