# Junie Local Installation Scripts

This repository stores installation scripts for local inference support in Junie.

## Purpose

These scripts are executed when a user runs the `/install-local-model` command in Junie. They handle the setup and installation of local inference models required for offline or self-hosted AI capabilities.

## Usage

Trigger the installation by running the following command in Junie:

```
/install-local-model
```

## What Gets Installed

- **Qwen3.6-27B-4bit** model archive (15 GB) → extracted to `~/.local/share/junie-local/models/`
- **Qwen3.6-27B-MTP-4bit** model archive (247 MB) → extracted to `~/.local/share/junie-local/models/`
- **oMLX 0.5.3** application → DMG is mounted for manual installation

## Resumable Downloads

Downloads are stored in `~/.local/share/junie-local/incomplete_downloads/`. If the script is interrupted (Ctrl+C, network failure, etc.), the partial downloads are preserved. Simply re-run the script and it will resume from where it left off using `curl -C -`.

Once all downloads are verified and extracted, the `incomplete_downloads` directory is automatically removed.