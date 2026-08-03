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

### Note on Terminal Behavior

When the script is run from Junie, the terminal window will close automatically when the script completes. The script displays a "press any key to exit" message at the end of every exit path to give you time to read the final output.

## Previewing the Installer UI

`preview.sh` replays every screen the installer draws — the logo, the system checks, the progress bar, the final summary — without installing anything:

```bash
./preview.sh                  # all screens with fake data, no network (~25 s)
JUNIE_NO_ANIM=1 ./preview.sh  # the plain output used in pipes and in CI
./preview.sh --resume-demo    # pre-seeds a partial file, then resumes it for real
./preview.sh --real           # real download; Ctrl+C, run it again, watch it resume
```

It does not carry its own copy of the UI code: it extracts the block between the `# --- junie-ui:begin ---` and `# --- junie-ui:end ---` markers from `install.sh` and sources it, so the preview always shows what the installer really draws. oMLX is never installed, `~/.omlx/settings.json` is never touched, and the `--real` modes download into `~/.cache/junie-local-preview` (override with `JUNIE_PREVIEW_DIR`).

A truecolor terminal is needed for the palette. The animations and the bar are skipped when the output is not a terminal, when `CI=true`, or when `JUNIE_NO_ANIM=1` — then the same numbers are logged once per 10% instead.

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

If the script is interrupted (Ctrl+C, etc.), the partial downloads remain. Simply re-run the script and it will resume from where it left off — the progress bar starts at the percentage already on disk instead of at zero.

A few details of that path:

- A file that already has the size the server reports is skipped after a single `HEAD` request, so re-running over a completed download costs nothing.
- An attempt that transferred something resets the backoff, so a flaky connection that keeps moving forward is not abandoned after three tries.
- An archive that fails its SHA256 check is deleted. Keeping it would make every later run resume into the same corrupt bytes and fail the same check forever.

Once all downloads are verified and extracted, the `incomplete_downloads` directory is automatically removed.