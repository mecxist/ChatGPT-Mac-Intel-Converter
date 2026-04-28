#!/usr/bin/env bash
set -euo pipefail

# Resolve script and workspace paths.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PARENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_BASE="${SCRIPT_DIR}/.tmp"
LOG_FILE="${SCRIPT_DIR}/log.txt"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
WORK_DIR="${TMP_BASE}/chatgpt_intel_build_${RUN_ID}"
MOUNT_POINT="${WORK_DIR}/mount"
KEEP_TEMP="${CHATGPT_INTEL_KEEP_TEMP:-0}"
NO_WEB_FALLBACK="${CHATGPT_INTEL_NO_FALLBACK:-0}"

# Runtime flags/state used by cleanup and mount logic.
ATTACHED_BY_SCRIPT=0
SOURCE_APP=""

# Filled after app detection.
APP_BUNDLE_NAME=""
APP_NAME=""
OUTPUT_DMG=""

# Candidate native modules to detect and rebuild.
MODULE_CANDIDATES=(
  "better-sqlite3"
  "node-pty"
  "keytar"
  "@vscode/sqlite3"
  "@parcel/watcher"
)

# Runtime-discovered modules.
DETECTED_MODULES=()


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
  ./build-intel.sh [path/to/ChatGPT.dmg | path/to/ChatGPT.app]

Behavior:
  - Reads source app from ../ChatGPT.app, ../ChatGPT.dmg, or explicit path argument
  - For Electron builds: rebuilds native modules for Intel and outputs converted DMG
  - For native/non-Electron builds: falls back to an Intel web-wrapper DMG by default
  - Uses .tmp/* for all build steps
  - Writes full logs to log.txt
  - Produces <AppName>AppMacIntel.dmg (for ChatGPT this is ChatGPTAppMacIntel.dmg)

Environment:
  CHATGPT_INTEL_NO_FALLBACK=1  # Disable web-wrapper fallback and fail on non-Electron apps
  CHATGPT_INTEL_KEEP_TEMP=1    # Keep .tmp build workspace on successful runs
USAGE_EOF
}

cleanup() {
  local exit_code=$?

  # Detach only if this script mounted the DMG itself.
  if [[ "${ATTACHED_BY_SCRIPT}" -eq 1 && -d "${MOUNT_POINT}" ]]; then
    hdiutil detach "${MOUNT_POINT}" >/dev/null 2>&1 || hdiutil detach -force "${MOUNT_POINT}" >/dev/null 2>&1 || true
  fi

  if [[ ${exit_code} -ne 0 ]]; then
    log "Build failed. See ${LOG_FILE}"
    log "Temporary files kept at: ${WORK_DIR}"
  else
    if [[ "${KEEP_TEMP}" == "1" ]]; then
      log "Keeping temporary files at: ${WORK_DIR}"
    else
      rm -rf "${WORK_DIR}" || true
      log "Cleaned temporary files"
    fi
  fi
}
trap cleanup EXIT

json_escape() {
  local text="$1"
  text="${text//\\/\\\\}"
  text="${text//\"/\\\"}"
  printf '%s' "$text"
}

module_version_from_pkg() {
  local pkg_file="$1"
  node -p "const p=require(process.argv[1]); p.version || ''" "${pkg_file}" 2>/dev/null || true
}

resolve_module_version() {
  local module_name="$1"
  local asar_file="$2"
  local asar_meta_dir="$3"
  local unpacked_pkg="${ORIG_APP}/Contents/Resources/app.asar.unpacked/node_modules/${module_name}/package.json"
  local safe_module_name
  local extracted_pkg
  local version=""

  if [[ -f "${unpacked_pkg}" ]]; then
    version="$(module_version_from_pkg "${unpacked_pkg}")"
    if [[ -n "${version}" ]]; then
      printf '%s' "${version}"
      return 0
    fi
  fi

  safe_module_name="${module_name//\//@}"
  safe_module_name="${safe_module_name//\//@}"
  safe_module_name="${safe_module_name//\//__}"
  extracted_pkg="${asar_meta_dir}/${safe_module_name}.package.json"

  if (
    cd "${asar_meta_dir}" &&
    npx --yes @electron/asar extract-file "${asar_file}" "node_modules/${module_name}/package.json" >/dev/null 2>&1
  ); then
    if [[ -f "${asar_meta_dir}/package.json" ]]; then
      mv "${asar_meta_dir}/package.json" "${extracted_pkg}"
      version="$(module_version_from_pkg "${extracted_pkg}")"
      if [[ -n "${version}" ]]; then
        printf '%s' "${version}"
        return 0
      fi
    fi
  fi

  printf ''
}

# Prepare log file and mirror output to console + log.txt.
mkdir -p "${TMP_BASE}"
: > "${LOG_FILE}"
if ! { exec > >(tee -a "${LOG_FILE}") 2>&1; } 2>/dev/null; then
  # Some restricted shells disallow /dev/fd process substitution.
  exec >> "${LOG_FILE}" 2>&1
fi

log "Starting Intel build pipeline"
log "Script dir: ${SCRIPT_DIR}"
log "Default source location: ${SCRIPT_PARENT_DIR}/ChatGPT.app or ${SCRIPT_PARENT_DIR}/ChatGPT.dmg"
log "Work dir: ${WORK_DIR}"
mkdir -p "${WORK_DIR}"

# Validate required tools early.
for cmd in hdiutil ditto npm npx node file codesign xattr find; do
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

# Resolve source input path:
# 1) explicit argument (.app or .dmg)
# 2) ../ChatGPT.app
# 3) ../ChatGPT.dmg
# 4) single *.app or *.dmg in parent directory
INPUT_DMG=""
INPUT_APP=""

if [[ $# -eq 1 ]]; then
  INPUT_PATH="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  if [[ -d "${INPUT_PATH}" && "${INPUT_PATH}" == *.app ]]; then
    INPUT_APP="${INPUT_PATH}"
  elif [[ -f "${INPUT_PATH}" && "${INPUT_PATH}" == *.dmg ]]; then
    INPUT_DMG="${INPUT_PATH}"
  else
    die "Input must be an existing .app bundle or .dmg file: ${INPUT_PATH}"
  fi
else
  if [[ -d "${SCRIPT_PARENT_DIR}/ChatGPT.app" ]]; then
    INPUT_APP="${SCRIPT_PARENT_DIR}/ChatGPT.app"
  elif [[ -f "${SCRIPT_PARENT_DIR}/ChatGPT.dmg" ]]; then
    INPUT_DMG="${SCRIPT_PARENT_DIR}/ChatGPT.dmg"
  else
    mapfile -t found_apps < <(find "${SCRIPT_PARENT_DIR}" -maxdepth 1 -type d -name "*.app" | sort)
    mapfile -t found_dmgs < <(find "${SCRIPT_PARENT_DIR}" -maxdepth 1 -type f -name "*.dmg" | sort)

    if [[ ${#found_apps[@]} -eq 1 ]]; then
      INPUT_APP="${found_apps[0]}"
    elif [[ ${#found_apps[@]} -gt 1 ]]; then
      printf '%s\n' "${found_apps[@]}"
      die "Multiple app bundles found. Pass source path explicitly."
    elif [[ ${#found_dmgs[@]} -eq 1 ]]; then
      INPUT_DMG="${found_dmgs[0]}"
    elif [[ ${#found_dmgs[@]} -gt 1 ]]; then
      printf '%s\n' "${found_dmgs[@]}"
      die "Multiple DMGs found. Pass source path explicitly."
    else
      die "No source .app or .dmg found. Put ChatGPT.app/ChatGPT.dmg next to this repo folder or pass a path."
    fi
  fi
fi

if [[ -n "${INPUT_APP}" ]]; then
  SOURCE_APP="${INPUT_APP}"
  log "Source app: ${SOURCE_APP}"
else
  [[ -f "${INPUT_DMG}" ]] || die "Source DMG not found: ${INPUT_DMG}"
  log "Source DMG: ${INPUT_DMG}"
  log "Mounting source DMG in read-only mode"
  mkdir -p "${MOUNT_POINT}"
  hdiutil attach -readonly -nobrowse -mountpoint "${MOUNT_POINT}" "${INPUT_DMG}" >/dev/null || die "Failed to mount source DMG"
  ATTACHED_BY_SCRIPT=1

  SOURCE_APP="$(find "${MOUNT_POINT}" -maxdepth 1 -type d -name "*.app" | head -n 1 || true)"
  [[ -n "${SOURCE_APP}" ]] || die "No .app bundle found inside DMG"
fi

[[ -d "${SOURCE_APP}" ]] || die "App bundle not found: ${SOURCE_APP}"

APP_BUNDLE_NAME="$(basename "${SOURCE_APP}")"
APP_NAME="${APP_BUNDLE_NAME%.app}"
OUTPUT_DMG="${SCRIPT_DIR}/${APP_NAME}AppMacIntel.dmg"

ORIG_APP="${WORK_DIR}/${APP_NAME}Original.app"
TARGET_APP="${WORK_DIR}/${APP_BUNDLE_NAME}"
BUILD_PROJECT="${WORK_DIR}/build-project"
DMG_ROOT="${WORK_DIR}/dmg-root"

log "Detected app bundle: ${APP_BUNDLE_NAME}"

# Copy app bundle from mounted DMG to local writable work dir.
log "Copying source app bundle to work dir"
ditto "${SOURCE_APP}" "${ORIG_APP}"

ASAR_FILE="${ORIG_APP}/Contents/Resources/app.asar"
if [[ ! -f "${ASAR_FILE}" ]]; then
  APP_EXECUTABLE="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "${ORIG_APP}/Contents/Info.plist" 2>/dev/null || true)"
  [[ -n "${APP_EXECUTABLE}" ]] || APP_EXECUTABLE="${APP_NAME}"
  MAIN_EXEC_PATH="${ORIG_APP}/Contents/MacOS/${APP_EXECUTABLE}"
  ARCH_NOTE=""
  if [[ -f "${MAIN_EXEC_PATH}" ]]; then
    ARCH_NOTE="$(file "${MAIN_EXEC_PATH}")"
  fi
  if [[ "${NO_WEB_FALLBACK}" == "1" ]]; then
    die "Source app is not Electron (app.asar is missing). Current ChatGPT desktop build appears native and cannot be converted by this Electron-based script. ${ARCH_NOTE}"
  fi

  WRAPPER_SCRIPT="${SCRIPT_DIR}/build-web-wrapper-intel.sh"
  [[ -x "${WRAPPER_SCRIPT}" ]] || die "Wrapper fallback script not found or not executable: ${WRAPPER_SCRIPT}"

  log "Source app is native/non-Electron. Running Intel web-wrapper fallback."
  log "Architecture detail: ${ARCH_NOTE}"
  "${WRAPPER_SCRIPT}" "${SOURCE_APP}"
  log "Fallback completed via ${WRAPPER_SCRIPT}"
  exit 0
fi

FRAMEWORK_INFO="$(find "${ORIG_APP}/Contents/Frameworks" -maxdepth 6 -type f -path "*/Resources/Info.plist" | grep -E " Framework\\.framework/.*/Resources/Info\\.plist" | head -n 1 || true)"
[[ -n "${FRAMEWORK_INFO}" && -f "${FRAMEWORK_INFO}" ]] || die "Cannot find Electron framework info plist in source app"
ELECTRON_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${FRAMEWORK_INFO}" 2>/dev/null || true)"
[[ -n "${ELECTRON_VERSION}" ]] || die "Cannot detect Electron version from source app framework metadata"

ASAR_META_DIR="${WORK_DIR}/asar-meta"
mkdir -p "${ASAR_META_DIR}"

log "Detected Electron version: ${ELECTRON_VERSION}"

# Detect native module versions from app bundle metadata.
DEPENDENCY_LINES=("    \"electron\": \"${ELECTRON_VERSION}\"")

for module_name in "${MODULE_CANDIDATES[@]}"; do
  version="$(resolve_module_version "${module_name}" "${ASAR_FILE}" "${ASAR_META_DIR}")"
  if [[ -n "${version}" ]]; then
    log "Detected native module: ${module_name}@${version}"
    DETECTED_MODULES+=("${module_name}")
    escaped_module="$(json_escape "${module_name}")"
    escaped_version="$(json_escape "${version}")"
    DEPENDENCY_LINES+=("    \"${escaped_module}\": \"${escaped_version}\"")
  fi
done

if [[ ${#DETECTED_MODULES[@]} -eq 0 ]]; then
  log "No known native modules detected from candidate list"
fi

# Build a temporary project to fetch x64 Electron/runtime artifacts.
log "Preparing x64 build project"
mkdir -p "${BUILD_PROJECT}"

{
  echo '{'
  echo '  "name": "chatgpt-intel-rebuild",'
  echo '  "private": true,'
  echo '  "version": "1.0.0",'
  echo '  "dependencies": {'
  dep_count="${#DEPENDENCY_LINES[@]}"
  for ((i = 0; i < dep_count; i++)); do
    if (( i < dep_count - 1 )); then
      echo "${DEPENDENCY_LINES[$i]},"
    else
      echo "${DEPENDENCY_LINES[$i]}"
    fi
  done
  echo '  },'
  echo '  "devDependencies": {'
  echo '    "@electron/rebuild": "3.7.2"'
  echo '  }'
  echo '}'
} > "${BUILD_PROJECT}/package.json"

(
  cd "${BUILD_PROJECT}"
  npm install --no-audit --no-fund
)

# Use Electron x64 app template as the destination runtime.
log "Creating Intel app bundle from Electron runtime"
ditto "${BUILD_PROJECT}/node_modules/electron/dist/Electron.app" "${TARGET_APP}"

# Inject original app resources into the x64 runtime shell.
log "Injecting app resources from original bundle"
rm -rf "${TARGET_APP}/Contents/Resources"
ditto "${ORIG_APP}/Contents/Resources" "${TARGET_APP}/Contents/Resources"
cp "${ORIG_APP}/Contents/Info.plist" "${TARGET_APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Electron" "${TARGET_APP}/Contents/Info.plist" >/dev/null

# Rebuild native modules against Electron x64 ABI when present.
if [[ ${#DETECTED_MODULES[@]} -gt 0 ]]; then
  MODULE_LIST="$(IFS=,; echo "${DETECTED_MODULES[*]}")"
  log "Rebuilding native modules for Electron ${ELECTRON_VERSION} x64: ${MODULE_LIST}"
  (
    cd "${BUILD_PROJECT}"
    npx --yes @electron/rebuild -f -w "${MODULE_LIST}" --arch=x64 --version "${ELECTRON_VERSION}" -m "${BUILD_PROJECT}"
  )
fi

TARGET_UNPACKED="${TARGET_APP}/Contents/Resources/app.asar.unpacked"
if [[ ! -d "${TARGET_UNPACKED}" ]]; then
  log "Target app.asar.unpacked not found, skipping native binary replacement"
else
  # Replace arm64 native artifacts with rebuilt x64 binaries where paths match.
  log "Replacing native binaries inside app.asar.unpacked"
  for module_name in "${DETECTED_MODULES[@]}"; do
    src_release="${BUILD_PROJECT}/node_modules/${module_name}/build/Release"
    dst_release="${TARGET_UNPACKED}/node_modules/${module_name}/build/Release"

    if [[ -d "${src_release}" && -d "${dst_release}" ]]; then
      while IFS= read -r src_node; do
        base_name="$(basename "${src_node}")"
        install -m 755 "${src_node}" "${dst_release}/${base_name}"
      done < <(find "${src_release}" -maxdepth 1 -type f -name "*.node")

      if [[ -f "${src_release}/spawn-helper" && -f "${dst_release}/spawn-helper" ]]; then
        install -m 755 "${src_release}/spawn-helper" "${dst_release}/spawn-helper"
      fi
    fi

    if [[ "${module_name}" == "node-pty" ]]; then
      node_pty_bin_src="$(find "${BUILD_PROJECT}/node_modules/node-pty/bin" -type f -name "node-pty.node" | grep "darwin-x64" | head -n 1 || true)"
      if [[ -n "${node_pty_bin_src}" ]]; then
        if compgen -G "${TARGET_UNPACKED}/node_modules/node-pty/bin/darwin-*" >/dev/null; then
          for target_dir in "${TARGET_UNPACKED}/node_modules/node-pty/bin"/darwin-*; do
            if [[ -d "${target_dir}" ]]; then
              install -m 755 "${node_pty_bin_src}" "${target_dir}/node-pty.node"
            fi
          done
        else
          mkdir -p "${TARGET_UNPACKED}/node_modules/node-pty/bin/darwin-x64-143"
          install -m 755 "${node_pty_bin_src}" "${TARGET_UNPACKED}/node_modules/node-pty/bin/darwin-x64-143/node-pty.node"
        fi
      fi
    fi
  done
fi

# Sanity-check key binaries before signing/packaging.
log "Validating main executable is x86_64"
main_exec_file="${TARGET_APP}/Contents/MacOS/Electron"
file_output="$(file "${main_exec_file}")"
echo "${file_output}"
[[ "${file_output}" == *"x86_64"* ]] || die "Expected x86_64 binary: ${main_exec_file}"

# Re-sign modified app ad-hoc to satisfy macOS code integrity checks.
log "Signing app ad-hoc"
xattr -cr "${TARGET_APP}" || true
codesign --force --deep --sign - --timestamp=none "${TARGET_APP}"
codesign --verify --deep --strict "${TARGET_APP}"

# Build final distributable DMG.
log "Building output DMG: ${OUTPUT_DMG}"
rm -f "${OUTPUT_DMG}"
mkdir -p "${DMG_ROOT}"
ditto "${TARGET_APP}" "${DMG_ROOT}/${APP_BUNDLE_NAME}"
ln -s /Applications "${DMG_ROOT}/Applications"
hdiutil create -volname "${APP_NAME} App Mac Intel" -srcfolder "${DMG_ROOT}" -ov -format UDZO "${OUTPUT_DMG}" >/dev/null

log "Done"
log "Output DMG: ${OUTPUT_DMG}"
log "Build log: ${LOG_FILE}"
log "Work dir: ${WORK_DIR}"
