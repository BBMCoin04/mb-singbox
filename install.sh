#!/usr/bin/env bash
# Bootstrap installer for mb-singbox.

set -uo pipefail
umask 077

INSTALLER_VERSION="0.5.2"
DEFAULT_REPO="BBMCoin04/mb-singbox"
REPO="${MB_SINGBOX_REPO:-$DEFAULT_REPO}"
REF="${MB_SINGBOX_REF:-main}"
INSTALL_PATH="${MB_SINGBOX_INSTALL_PATH:-/usr/local/sbin/mb-singbox}"
QUICK_PATH="${MB_SINGBOX_QUICK_PATH:-/usr/local/bin/mb-singbox}"
LEGACY_QUICK_PATH="${MB_SINGBOX_LEGACY_QUICK_PATH:-/usr/local/bin/singbox}"
CACHE_BUST="$(date +%s)"
SOURCE_URL="${MB_SINGBOX_SOURCE_URL:-https://raw.githubusercontent.com/${REPO}/${REF}/mb-singbox.sh?ts=${CACHE_BUST}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
BUNDLED_SOURCE=""
if [[ -z "${MB_SINGBOX_SOURCE_URL+x}" && -n "$SCRIPT_DIR" && -s "${SCRIPT_DIR}/mb-singbox.sh" ]]; then
  BUNDLED_SOURCE="${SCRIPT_DIR}/mb-singbox.sh"
fi
TEMP_FILE=""
BACKUP_FILE=""
QUICK_CREATED=0
LEGACY_CREATED=0

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_CYAN=$'\033[36m'
  C_RESET=$'\033[0m'
else
  C_RED=""
  C_GREEN=""
  C_CYAN=""
  C_RESET=""
fi

info() { printf '%s[信息]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok() { printf '%s[完成]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
error() { printf '%s[错误]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

cleanup() {
  [[ -z "$TEMP_FILE" ]] || rm -f -- "$TEMP_FILE"
  [[ -z "$BACKUP_FILE" ]] || rm -f -- "$BACKUP_FILE"
}
trap cleanup EXIT HUP INT TERM

if (( EUID != 0 )); then
  error "安装需要 root 权限，请在命令前使用 sudo。"
  exit 1
fi
if [[ "$INSTALL_PATH" != /* || "$(basename "$INSTALL_PATH")" != "mb-singbox" ]]; then
  error "管理器安装路径必须是绝对路径，并以 mb-singbox 结尾。"
  exit 1
fi
if [[ "$QUICK_PATH" != /* || "$(basename "$QUICK_PATH")" != "mb-singbox" ]]; then
  error "主命令路径必须是绝对路径，并以 mb-singbox 结尾。"
  exit 1
fi
if [[ "$LEGACY_QUICK_PATH" != /* || "$(basename "$LEGACY_QUICK_PATH")" != "singbox" ]]; then
  error "兼容命令路径必须是绝对路径，并以 singbox 结尾。"
  exit 1
fi

for command_name in install bash; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    error "缺少必要命令：${command_name}"
    exit 1
  fi
done
if [[ -z "$BUNDLED_SOURCE" && "$SOURCE_URL" != https://* ]]; then
  error "仅允许从 HTTPS 地址下载主程序。"
  exit 1
fi

TEMP_FILE="$(mktemp /tmp/mb-singbox.XXXXXX.sh)" || exit 1
info "MB sing-box 管理器引导安装器 ${INSTALLER_VERSION}"
if [[ -n "$BUNDLED_SOURCE" ]]; then
  info "正在使用安装包内的 mb-singbox.sh"
  if ! cp "$BUNDLED_SOURCE" "$TEMP_FILE"; then
    error "无法读取安装包内的主程序。"
    exit 1
  fi
else
  info "正在下载 ${SOURCE_URL}"
  if command -v curl >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 -fsSL "$SOURCE_URL" -o "$TEMP_FILE"
    download_rc=$?
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$TEMP_FILE" "$SOURCE_URL"
    download_rc=$?
  else
    error "需要 curl 或 wget 才能下载安装。"
    exit 1
  fi
  if (( download_rc != 0 )); then
    error "下载失败，请检查仓库地址和网络。"
    exit 1
  fi
fi

if [[ ! -s "$TEMP_FILE" ]]; then
  error "下载结果为空，拒绝安装。"
  exit 1
fi
if ! bash -n "$TEMP_FILE"; then
  error "下载的脚本未通过 Bash 语法检查，拒绝安装。"
  exit 1
fi
if ! grep -q '^PROGRAM="mb-singbox"$' "$TEMP_FILE"; then
  error "下载内容不是预期的 MB sing-box 管理器主程序，拒绝安装。"
  exit 1
fi
MANAGER_VERSION="$(awk -F '"' '/^VERSION="[0-9]/{print $2; exit}' "$TEMP_FILE")"
if [[ ! "$MANAGER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  error "无法识别管理器版本，拒绝安装。"
  exit 1
fi
info "准备安装 MB sing-box 管理器 ${MANAGER_VERSION}"

install -d -m 0755 "$(dirname "$INSTALL_PATH")" "$(dirname "$QUICK_PATH")" "$(dirname "$LEGACY_QUICK_PATH")" || {
  error "无法创建管理器安装目录。"
  exit 1
}
if [[ -L "$INSTALL_PATH" ]]; then
  error "安装目标不能是软链接：${INSTALL_PATH}"
  exit 1
fi
if [[ ( -e "$QUICK_PATH" || -L "$QUICK_PATH" ) && "$(readlink -f "$QUICK_PATH" 2>/dev/null || true)" != "$INSTALL_PATH" ]]; then
  error "${QUICK_PATH} 已被其他程序占用，不会覆盖或继续安装。"
  error "请先确认并处理该文件，再重新运行安装器。"
  exit 1
fi
if [[ -f "$INSTALL_PATH" ]]; then
  BACKUP_FILE="$(mktemp /tmp/mb-singbox-existing.XXXXXX.sh)" || exit 1
  cp -a -- "$INSTALL_PATH" "$BACKUP_FILE" || exit 1
fi
if ! install -m 0755 "$TEMP_FILE" "$INSTALL_PATH"; then
  [[ ! -s "$BACKUP_FILE" ]] || install -m 0755 "$BACKUP_FILE" "$INSTALL_PATH" || true
  error "无法安装管理器到 ${INSTALL_PATH}，已尝试恢复原版本。"
  exit 1
fi
if [[ ! -e "$QUICK_PATH" && ! -L "$QUICK_PATH" ]]; then
  if ! ln -s "$INSTALL_PATH" "$QUICK_PATH"; then
    if [[ -s "$BACKUP_FILE" ]]; then
      install -m 0755 "$BACKUP_FILE" "$INSTALL_PATH" || true
    else
      rm -f -- "$INSTALL_PATH"
    fi
    error "无法创建主命令 ${QUICK_PATH}，已尝试恢复原管理器。"
    exit 1
  fi
  QUICK_CREATED=1
fi
if [[ ! -e "$LEGACY_QUICK_PATH" && ! -L "$LEGACY_QUICK_PATH" ]]; then
  if ln -s "$INSTALL_PATH" "$LEGACY_QUICK_PATH"; then
    LEGACY_CREATED=1
  else
    info "兼容命令 ${LEGACY_QUICK_PATH} 创建失败；主命令不受影响。"
  fi
elif [[ "$(readlink -f "$LEGACY_QUICK_PATH" 2>/dev/null || true)" != "$INSTALL_PATH" ]]; then
  info "${LEGACY_QUICK_PATH} 已被其他程序占用，仅安装主命令 ${QUICK_PATH}。"
fi
hash_value="$(sha256sum "$INSTALL_PATH" 2>/dev/null | awk '{print $1}' || true)"
if [[ "$("$INSTALL_PATH" version 2>/dev/null)" != "mb-singbox ${MANAGER_VERSION}" ]]; then
  (( QUICK_CREATED == 0 )) || rm -f -- "$QUICK_PATH"
  (( LEGACY_CREATED == 0 )) || rm -f -- "$LEGACY_QUICK_PATH"
  if [[ -s "$BACKUP_FILE" ]]; then
    install -m 0755 "$BACKUP_FILE" "$INSTALL_PATH" || true
  else
    rm -f -- "$INSTALL_PATH"
  fi
  error "安装后的版本自检失败，已恢复原版本。"
  exit 1
fi
ok "MB sing-box 管理器 ${MANAGER_VERSION} 已安装到 ${INSTALL_PATH}"
ok "主命令：${QUICK_PATH} -> ${INSTALL_PATH}"
[[ "$(readlink -f "$LEGACY_QUICK_PATH" 2>/dev/null || true)" == "$INSTALL_PATH" ]] && \
  ok "兼容命令：${LEGACY_QUICK_PATH} -> ${INSTALL_PATH}"
[[ -n "$hash_value" ]] && printf 'SHA-256: %s\n' "$hash_value"

cleanup
TEMP_FILE=""
BACKUP_FILE=""
trap - EXIT HUP INT TERM

if (( $# > 0 )); then
  exec "$INSTALL_PATH" "$@"
fi

if [[ -r /dev/tty && -w /dev/tty ]]; then
  exec "$INSTALL_PATH" </dev/tty >/dev/tty
fi

info "当前环境没有交互终端。稍后运行：sudo mb-singbox"
