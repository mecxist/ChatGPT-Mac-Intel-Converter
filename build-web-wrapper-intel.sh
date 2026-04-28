#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PARENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_BASE="${SCRIPT_DIR}/.tmp"
LOG_FILE="${SCRIPT_DIR}/web-wrapper-log.txt"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
WORK_DIR="${TMP_BASE}/chatgpt_web_wrapper_build_${RUN_ID}"
MOUNT_POINT="${WORK_DIR}/mount"

ATTACHED_BY_SCRIPT=0
SOURCE_APP=""
SOURCE_DMG=""

APP_BUNDLE_NAME="ChatGPT Intel.app"
APP_NAME="ChatGPT Intel"
OUTPUT_DMG="${SCRIPT_DIR}/ChatGPTIntel.dmg"
START_URL="${CHATGPT_WEB_URL:-https://chatgpt.com/}"
KEEP_TEMP="${CHATGPT_INTEL_KEEP_TEMP:-0}"


timestamp() {
  date "+%Y-%m-%d %H:%M:%S"
}

log() {
  printf "[%s] %s\n" "$(timestamp)" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

usage() {
  cat <<'USAGE_EOF'
Usage:
  ./build-web-wrapper-intel.sh [path/to/ChatGPT.app | path/to/ChatGPT.dmg]

Behavior:
  - Builds a standalone Intel Electron wrapper that opens ChatGPT Web
  - Uses source app only for icon extraction when available
  - Writes logs to web-wrapper-log.txt
  - Produces ChatGPTIntel.dmg

Environment:
  CHATGPT_WEB_URL=https://chatgpt.com/  # Optional startup URL
  CHATGPT_INTEL_KEEP_TEMP=1             # Keep .tmp build workspace on success
USAGE_EOF
}

cleanup() {
  local exit_code=$?

  if [[ "${ATTACHED_BY_SCRIPT}" -eq 1 && -d "${MOUNT_POINT}" ]]; then
    hdiutil detach "${MOUNT_POINT}" >/dev/null 2>&1 || hdiutil detach -force "${MOUNT_POINT}" >/dev/null 2>&1 || true
  fi

  if [[ ${exit_code} -eq 0 ]]; then
    if [[ "${KEEP_TEMP}" == "1" ]]; then
      log "Keeping temporary files at: ${WORK_DIR}"
    else
      rm -rf "${WORK_DIR}" || true
      log "Cleaned temporary files"
    fi
  else
    log "Build failed. See ${LOG_FILE}"
    log "Temporary files kept at: ${WORK_DIR}"
  fi
}
trap cleanup EXIT

mkdir -p "${TMP_BASE}"
: > "${LOG_FILE}"
if ! { exec > >(tee -a "${LOG_FILE}") 2>&1; } 2>/dev/null; then
  exec >> "${LOG_FILE}" 2>&1
fi

log "Starting ChatGPT Intel wrapper build"
log "Script dir: ${SCRIPT_DIR}"
log "Work dir: ${WORK_DIR}"
mkdir -p "${WORK_DIR}"

for cmd in hdiutil ditto npm node file codesign xattr find /usr/libexec/PlistBuddy; do
  command -v "${cmd}" >/dev/null 2>&1 || die "Missing required command: ${cmd}"
done

if [[ $# -gt 0 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  usage
  exit 0
fi

if [[ $# -gt 1 ]]; then
  usage
  die "Too many arguments"
fi

resolve_source_input() {
  local arg_path="${1:-}"

  if [[ -n "${arg_path}" ]]; then
    local resolved
    resolved="$(cd "$(dirname "${arg_path}")" && pwd)/$(basename "${arg_path}")"
    if [[ -d "${resolved}" && "${resolved}" == *.app ]]; then
      SOURCE_APP="${resolved}"
      return
    fi
    if [[ -f "${resolved}" && "${resolved}" == *.dmg ]]; then
      SOURCE_DMG="${resolved}"
      return
    fi
    die "Input must be an existing .app bundle or .dmg file: ${resolved}"
  fi

  if [[ -d "${SCRIPT_PARENT_DIR}/ChatGPT.app" ]]; then
    SOURCE_APP="${SCRIPT_PARENT_DIR}/ChatGPT.app"
    return
  fi

  if [[ -f "${SCRIPT_PARENT_DIR}/ChatGPT.dmg" ]]; then
    SOURCE_DMG="${SCRIPT_PARENT_DIR}/ChatGPT.dmg"
    return
  fi

  mapfile -t found_apps < <(find "${SCRIPT_PARENT_DIR}" -maxdepth 1 -type d -name "*.app" | sort)
  mapfile -t found_dmgs < <(find "${SCRIPT_PARENT_DIR}" -maxdepth 1 -type f -name "*.dmg" | sort)

  if [[ ${#found_apps[@]} -eq 1 ]]; then
    SOURCE_APP="${found_apps[0]}"
    return
  fi

  if [[ ${#found_dmgs[@]} -eq 1 ]]; then
    SOURCE_DMG="${found_dmgs[0]}"
    return
  fi
}

resolve_source_input "${1:-}"

if [[ -n "${SOURCE_DMG}" ]]; then
  [[ -f "${SOURCE_DMG}" ]] || die "Source DMG not found: ${SOURCE_DMG}"
  log "Using source DMG for icon extraction: ${SOURCE_DMG}"
  mkdir -p "${MOUNT_POINT}"
  hdiutil attach -readonly -nobrowse -mountpoint "${MOUNT_POINT}" "${SOURCE_DMG}" >/dev/null || die "Failed to mount source DMG"
  ATTACHED_BY_SCRIPT=1

  SOURCE_APP="$(find "${MOUNT_POINT}" -maxdepth 1 -type d -name "*.app" | head -n 1 || true)"
fi

if [[ -n "${SOURCE_APP}" && -d "${SOURCE_APP}" ]]; then
  log "Using source app for icon extraction: ${SOURCE_APP}"
else
  SOURCE_APP=""
  log "No source app found; wrapper will use default Electron icon"
fi

BUILD_PROJECT="${WORK_DIR}/build-project"
TARGET_APP="${WORK_DIR}/${APP_BUNDLE_NAME}"
WRAPPER_SOURCE="${WORK_DIR}/wrapper-source"
DMG_ROOT="${WORK_DIR}/dmg-root"

mkdir -p "${BUILD_PROJECT}" "${WRAPPER_SOURCE}"

cat > "${BUILD_PROJECT}/package.json" <<'PKG_EOF'
{
  "name": "chatgpt-web-wrapper-intel",
  "private": true,
  "version": "1.0.0",
  "dependencies": {
    "electron": "latest"
  }
}
PKG_EOF

log "Installing Electron x64 runtime"
HOST_ARCH="$(uname -m)"
if [[ "${HOST_ARCH}" == "x86_64" ]]; then
  (
    cd "${BUILD_PROJECT}"
    npm install --no-audit --no-fund
  )
elif arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
  log "Host is ${HOST_ARCH}; using Rosetta x86_64 npm for Intel runtime"
  (
    cd "${BUILD_PROJECT}"
    arch -x86_64 npm install --no-audit --no-fund
  )
else
  die "Host is ${HOST_ARCH} and Rosetta x86_64 execution is unavailable. Run this script on an Intel Mac or install Rosetta."
fi

ELECTRON_APP="${BUILD_PROJECT}/node_modules/electron/dist/Electron.app"
[[ -d "${ELECTRON_APP}" ]] || die "Electron runtime app not found after npm install"

log "Creating wrapper app bundle"
ditto "${ELECTRON_APP}" "${TARGET_APP}"

cat > "${WRAPPER_SOURCE}/package.json" <<'WRAPPER_PKG_EOF'
{
  "name": "chatgpt-web-intel-wrapper",
  "version": "1.0.0",
  "main": "main.js"
}
WRAPPER_PKG_EOF

cat > "${WRAPPER_SOURCE}/main.js" <<'MAIN_EOF'
const { app, BrowserWindow, shell } = require("electron");

const START_URL = process.env.CHATGPT_WEB_URL || "https://chatgpt.com/";
const ALLOWED_HOST_PATTERNS = [
  /(^|\.)chatgpt\.com$/i,
  /(^|\.)openai\.com$/i,
  /(^|\.)oaistatic\.com$/i
];

function isAllowedInApp(url) {
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== "https:") {
      return false;
    }
    return ALLOWED_HOST_PATTERNS.some((pattern) => pattern.test(parsed.hostname));
  } catch {
    return false;
  }
}

function createMainWindow() {
  const win = new BrowserWindow({
    width: 1280,
    height: 820,
    minWidth: 980,
    minHeight: 640,
    autoHideMenuBar: true,
    title: "ChatGPT Intel",
    webPreferences: {
      contextIsolation: true,
      sandbox: true,
      partition: "persist:chatgpt-web-intel"
    }
  });

  win.webContents.setWindowOpenHandler(({ url }) => {
    if (isAllowedInApp(url)) {
      return { action: "allow" };
    }
    shell.openExternal(url);
    return { action: "deny" };
  });

  win.webContents.on("will-navigate", (event, url) => {
    if (!isAllowedInApp(url)) {
      event.preventDefault();
      shell.openExternal(url);
    }
  });

  win.loadURL(START_URL);
}

app.whenReady().then(() => {
  createMainWindow();

  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createMainWindow();
    }
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});
MAIN_EOF

rm -rf "${TARGET_APP}/Contents/Resources/app"
mkdir -p "${TARGET_APP}/Contents/Resources/app"
ditto "${WRAPPER_SOURCE}" "${TARGET_APP}/Contents/Resources/app"

/usr/libexec/PlistBuddy -c "Set :CFBundleName ${APP_NAME}" "${TARGET_APP}/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${APP_NAME}" "${TARGET_APP}/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.openai.chatgpt.web.intel.wrapper" "${TARGET_APP}/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.0.0" "${TARGET_APP}/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${RUN_ID}" "${TARGET_APP}/Contents/Info.plist" >/dev/null

if [[ -n "${SOURCE_APP}" ]]; then
  icon_file="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "${SOURCE_APP}/Contents/Info.plist" 2>/dev/null || true)"
  if [[ -n "${icon_file}" && "${icon_file}" != *.icns ]]; then
    icon_file="${icon_file}.icns"
  fi

  if [[ -n "${icon_file}" && -f "${SOURCE_APP}/Contents/Resources/${icon_file}" ]]; then
    cp "${SOURCE_APP}/Contents/Resources/${icon_file}" "${TARGET_APP}/Contents/Resources/${icon_file}"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile ${icon_file}" "${TARGET_APP}/Contents/Info.plist" >/dev/null
    log "Copied source app icon: ${icon_file}"
  else
    fallback_icon="$(find "${SOURCE_APP}/Contents/Resources" -maxdepth 1 -type f -name "*.icns" | head -n 1 || true)"
    if [[ -n "${fallback_icon}" ]]; then
      fallback_icon_name="$(basename "${fallback_icon}")"
      cp "${fallback_icon}" "${TARGET_APP}/Contents/Resources/${fallback_icon_name}"
      /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile ${fallback_icon_name}" "${TARGET_APP}/Contents/Info.plist" >/dev/null
      log "Copied fallback icon: ${fallback_icon_name}"
    fi
  fi
fi

log "Validating wrapper runtime architecture"
main_exec_file="${TARGET_APP}/Contents/MacOS/Electron"
file_output="$(file "${main_exec_file}")"
echo "${file_output}"
[[ "${file_output}" == *"x86_64"* ]] || die "Expected x86_64 binary: ${main_exec_file}"

log "Signing wrapper app"
xattr -cr "${TARGET_APP}" || true
codesign --force --deep --sign - --timestamp=none "${TARGET_APP}"
codesign --verify --deep --strict "${TARGET_APP}"

log "Building output DMG: ${OUTPUT_DMG}"
rm -f "${OUTPUT_DMG}"
mkdir -p "${DMG_ROOT}"
ditto "${TARGET_APP}" "${DMG_ROOT}/${APP_BUNDLE_NAME}"
ln -s /Applications "${DMG_ROOT}/Applications"
hdiutil create -volname "${APP_NAME}" -srcfolder "${DMG_ROOT}" -ov -format UDZO "${OUTPUT_DMG}" >/dev/null

log "Done"
log "Output DMG: ${OUTPUT_DMG}"
log "Build log: ${LOG_FILE}"
