# ChatGPT Intel Builder for macOS (Unofficial)

Built by **m.j. zilla**.
- Substack: [mecxist.substack.com](https://mecxist.substack.com/)

## Disclaimer

This is an **unofficial conversion tool** and is provided for **educational purposes only**.
It is not affiliated with or endorsed by OpenAI. Use at your own risk.

## What This Project Does

This project takes `ChatGPT.dmg` as input and produces `ChatGPTIntel.dmg` for Intel Macs.

## Files

- `build-intel.sh` - main build command
- `build-web-wrapper-intel.sh` - wrapper build helper
- `package.json` - optional npm script helpers
- `.gitignore` - ignores local artifacts

## Requirements

- macOS
- `bash`, `hdiutil`, `ditto`, `codesign`, `xattr`
- Node.js + npm
- Network access to npm registry (for Electron download)

## Quick Start

Keep files in this layout:

```mermaid
flowchart TD
  A["~/path/to/your/workspace/"]
  B["ChatGPT.dmg"]
  C["ChatGPT-Mac-Intel-Converter/"]
  D["build-intel.sh"]
  E["build-web-wrapper-intel.sh"]
  F["README.md"]
  A --> B
  A --> C
  C --> D
  C --> E
  C --> F
```

Use any local folder layout you prefer, then pass the correct DMG path to the script.

### 1) Go to the converter folder
# (If you're already in this folder skip to step 2):

```bash
cd ~/path/to/your/workspace/ChatGPT-Mac-Intel-Converter
```

### 2) Run this (copy/paste)

```bash
chmod +x ./build-intel.sh ./build-web-wrapper-intel.sh
./build-intel.sh ~/path/to/your/workspace/ChatGPT.dmg
```

### 3) Result

After a successful run, you should get:

- `ChatGPTIntel.dmg`

## Outputs

- `ChatGPTIntel.dmg` - Intel wrapper output (most common with current native ChatGPT builds)
- `log.txt` - main build log
- `web-wrapper-log.txt` - wrapper build log

## Troubleshooting

- If npm download fails, check internet/proxy settings.
- If code signing fails, re-run and review `log.txt`.
- If you are on Apple Silicon and wrapper build fails for x64 tooling, ensure Rosetta is installed.
