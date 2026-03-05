#!/usr/bin/env bash
set -euo pipefail

APP="hyperset-runner"
DIST_REPO="${HYPERSET_RUNNER_DIST_REPO:-hypersetai/get-runner}"
DIST_BRANCH="${HYPERSET_RUNNER_DIST_BRANCH:-main}"
HYPERSET_HOME="${HYPERSET_HOME:-${HOME}/.hyperset}"
INSTALL_DIR="${HYPERSET_HOME}/runner/bin"
RECEIPT_PATH="${HYPERSET_HOME}/runner/install.json"
RUNNER_ROOT="${HYPERSET_HOME}/runner"
REQUESTED_VERSION="${VERSION:-}"
NO_MODIFY_PATH="false"
DO_UNINSTALL="false"
DO_PURGE="false"

usage() {
  cat <<EOF
Hyperset Runner Installer

Usage: install.sh [options]

Options:
  -h, --help                 Show help
  -v, --version <version>    Install specific version (e.g. 1.2.3 or v1.2.3)
      --install-dir <path>   Install directory (default: \$HYPERSET_HOME/runner/bin)
      --no-modify-path       Do not edit shell config
      --uninstall            Remove installed binary
      --purge                Remove installed binary and \$HYPERSET_HOME/runner state

Examples:
  curl -fsSL https://raw.githubusercontent.com/hypersetai/get-runner/main/install.sh | bash
  curl -fsSL https://raw.githubusercontent.com/hypersetai/get-runner/main/install.sh | bash -s -- --version 1.2.3
  curl -fsSL https://raw.githubusercontent.com/hypersetai/get-runner/main/install.sh | bash -s -- --uninstall
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -v|--version)
      REQUESTED_VERSION="${2:-}"
      if [[ -z "${REQUESTED_VERSION}" ]]; then
        echo "Error: --version requires a value"
        exit 1
      fi
      shift 2
      ;;
    --install-dir)
      INSTALL_DIR="${2:-}"
      if [[ -z "${INSTALL_DIR}" ]]; then
        echo "Error: --install-dir requires a path"
        exit 1
      fi
      shift 2
      ;;
    --no-modify-path)
      NO_MODIFY_PATH="true"
      shift
      ;;
    --uninstall)
      DO_UNINSTALL="true"
      shift
      ;;
    --purge)
      DO_PURGE="true"
      shift
      ;;
    *)
      echo "Warning: ignoring unknown argument: $1"
      shift
      ;;
  esac
done

detect_target() {
  local raw_os raw_arch os arch
  raw_os="$(uname -s)"
  raw_arch="$(uname -m)"

  case "${raw_os}" in
    Darwin*) os="darwin" ;;
    Linux*) os="linux" ;;
    MINGW*|MSYS*|CYGWIN*) os="win32" ;;
    *)
      echo "Unsupported OS: ${raw_os}"
      exit 1
      ;;
  esac

  case "${raw_arch}" in
    x86_64|amd64) arch="x64" ;;
    arm64|aarch64) arch="arm64" ;;
    *)
      echo "Unsupported architecture: ${raw_arch}"
      exit 1
      ;;
  esac

  echo "${os}-${arch}"
}

sha256_cmd() {
  if command -v sha256sum >/dev/null 2>&1; then
    echo "sha256sum"
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    echo "shasum"
    return
  fi
  echo ""
}

json_python() {
  python3 - "$@"
}

extract_from_manifest() {
  local manifest_file="$1"
  local target="$2"
  local field="$3"
  json_python "${manifest_file}" "${target}" "${field}" <<'PY'
import json, sys
manifest_path, target, field = sys.argv[1], sys.argv[2], sys.argv[3]
with open(manifest_path, "r", encoding="utf-8") as f:
    data = json.load(f)
targets = data.get("targets", {})
entry = targets.get(target, {})
value = entry.get(field, "")
print(value)
PY
}

extract_manifest_version() {
  local manifest_file="$1"
  json_python "${manifest_file}" <<'PY'
import json, sys
manifest_path = sys.argv[1]
with open(manifest_path, "r", encoding="utf-8") as f:
    data = json.load(f)
print((data.get("version") or "").strip())
PY
}

write_install_receipt() {
  local installed_version="$1"
  mkdir -p "$(dirname "${RECEIPT_PATH}")"
  json_python "${RECEIPT_PATH}" "${INSTALL_DIR}" "${installed_version}" <<'PY'
import json, sys, datetime
receipt_path, install_dir, version = sys.argv[1], sys.argv[2], sys.argv[3]
payload = {
    "channel": "curl",
    "version": version,
    "install_dir": install_dir,
    "installed_at": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
}
with open(receipt_path, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)
    f.write("\n")
PY
}

remove_install_receipt() {
  if [[ -f "${RECEIPT_PATH}" ]]; then
    rm -f "${RECEIPT_PATH}"
  fi
}

ensure_installer_requirements() {
  if ! command -v curl >/dev/null 2>&1; then
    echo "Error: curl is required."
    exit 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required by this installer."
    exit 1
  fi
}

perform_uninstall() {
  local removed="false"
  if [[ -f "${INSTALL_DIR}/${APP}" ]]; then
    rm -f "${INSTALL_DIR}/${APP}"
    removed="true"
  fi
  if [[ "${removed}" = "true" ]]; then
    echo "Removed ${APP} from ${INSTALL_DIR}"
  else
    echo "No installed binary found in ${INSTALL_DIR}"
  fi
  remove_install_receipt
  if [[ "${DO_PURGE}" = "true" ]]; then
    rm -rf "${RUNNER_ROOT}"
    echo "Purged ${RUNNER_ROOT}"
  fi
}

update_path() {
  if [[ "${NO_MODIFY_PATH}" = "true" ]]; then
    echo "Skipping PATH modification (--no-modify-path)."
    return
  fi
  if [[ ":${PATH}:" == *":${INSTALL_DIR}:"* ]]; then
    return
  fi
  local shell_name config_file command
  shell_name="$(basename "${SHELL:-bash}")"
  case "${shell_name}" in
    zsh) config_file="${HOME}/.zshrc" ;;
    fish) config_file="${HOME}/.config/fish/config.fish" ;;
    *) config_file="${HOME}/.bashrc" ;;
  esac
  if [[ "${shell_name}" = "fish" ]]; then
    command="fish_add_path ${INSTALL_DIR}"
  else
    command="export PATH=${INSTALL_DIR}:\$PATH"
  fi
  mkdir -p "$(dirname "${config_file}")"
  touch "${config_file}"
  if ! grep -Fqx "${command}" "${config_file}"; then
    {
      echo ""
      echo "# hyperset-runner"
      echo "${command}"
    } >> "${config_file}"
    echo "Added ${INSTALL_DIR} to PATH in ${config_file}"
  fi
}

download_and_install() {
  local target version_tag manifest_url archive_url checksum archive_name archive_file tmp_dir sha_cmd actual installed_version
  target="$(detect_target)"
  case "${target}" in
    darwin-x64|darwin-arm64|linux-x64|linux-arm64|win32-x64) ;;
    *)
      echo "Unsupported target for installer MVP: ${target}"
      exit 1
      ;;
  esac

  if [[ -n "${REQUESTED_VERSION}" ]]; then
    version_tag="v${REQUESTED_VERSION#v}"
    manifest_url="https://github.com/${DIST_REPO}/releases/download/${version_tag}/manifest.json"
  else
    manifest_url="https://raw.githubusercontent.com/${DIST_REPO}/${DIST_BRANCH}/manifest.json"
  fi

  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' EXIT
  curl -fsSL "${manifest_url}" -o "${tmp_dir}/manifest.json"
  installed_version="$(extract_manifest_version "${tmp_dir}/manifest.json")"
  archive_url="$(extract_from_manifest "${tmp_dir}/manifest.json" "${target}" "url")"
  checksum="$(extract_from_manifest "${tmp_dir}/manifest.json" "${target}" "sha256")"
  if [[ -z "${archive_url}" || -z "${checksum}" ]]; then
    echo "Error: manifest missing url/sha256 for target ${target}"
    exit 1
  fi

  archive_name="$(basename "${archive_url}")"
  archive_file="${tmp_dir}/${archive_name}"
  curl -fsSL "${archive_url}" -o "${archive_file}"

  sha_cmd="$(sha256_cmd)"
  if [[ -z "${sha_cmd}" ]]; then
    echo "Error: sha256sum or shasum is required."
    exit 1
  fi
  if [[ "${sha_cmd}" = "sha256sum" ]]; then
    actual="$(sha256sum "${archive_file}" | awk '{print $1}')"
  else
    actual="$(shasum -a 256 "${archive_file}" | awk '{print $1}')"
  fi
  if [[ "${actual}" != "${checksum}" ]]; then
    echo "Error: checksum mismatch for ${archive_name}"
    exit 1
  fi

  mkdir -p "${INSTALL_DIR}"
  if [[ "${archive_name}" == *.zip ]]; then
    if ! command -v unzip >/dev/null 2>&1; then
      echo "Error: unzip is required for ${archive_name}"
      exit 1
    fi
    unzip -q "${archive_file}" -d "${tmp_dir}/extract"
  else
    mkdir -p "${tmp_dir}/extract"
    tar -xzf "${archive_file}" -C "${tmp_dir}/extract"
  fi

  local bin_name
  if [[ "${target}" == win32-* ]]; then
    bin_name="hyperset-runner.exe"
  else
    bin_name="hyperset-runner"
  fi
  if [[ ! -f "${tmp_dir}/extract/${bin_name}" ]]; then
    echo "Error: ${bin_name} missing from archive"
    exit 1
  fi
  mv "${tmp_dir}/extract/${bin_name}" "${INSTALL_DIR}/${APP}"
  chmod 755 "${INSTALL_DIR}/${APP}"
  if [[ -z "${installed_version}" ]]; then
    installed_version="${REQUESTED_VERSION#v}"
  fi
  write_install_receipt "${installed_version:-unknown}"
  echo "Installed ${APP} to ${INSTALL_DIR}/${APP}"
}

main() {
  ensure_installer_requirements
  if [[ "${DO_UNINSTALL}" = "true" || "${DO_PURGE}" = "true" ]]; then
    perform_uninstall
    exit 0
  fi
  download_and_install
  update_path
  echo "Run: ${APP} --version"
}

main "$@"
