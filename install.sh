#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_NAME="remnawave-node-installer"
readonly MANAGED_MARKER="# Managed by ${SCRIPT_NAME}."

INSTALL_DIR="${REMNAWAVE_INSTALL_DIR:-/opt/remnanode}"
NODE_PORT="${REMNAWAVE_NODE_PORT:-2222}"
SECRET_KEY_VALUE="${REMNAWAVE_SECRET_KEY:-}"
DRY_RUN="${REMNAWAVE_DRY_RUN:-0}"
COMPOSE_FILE=""
ENV_FILE=""
TEMP_ENV=""
TEMP_COMPOSE=""

if [[ -t 1 ]]; then
  COLOR_RED=$'\033[31m'
  COLOR_GREEN=$'\033[32m'
  COLOR_YELLOW=$'\033[33m'
  COLOR_CYAN=$'\033[36m'
  COLOR_RESET=$'\033[0m'
else
  COLOR_RED=""
  COLOR_GREEN=""
  COLOR_YELLOW=""
  COLOR_CYAN=""
  COLOR_RESET=""
fi

log() {
  printf '%s[Remnawave]%s %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$*"
}

success() {
  printf '%s[完成]%s %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"
}

warn() {
  printf '%s[注意]%s %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2
}

die() {
  printf '%s[错误]%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Remnawave Node 一键安装脚本

用法：
  bash install.sh [--port PORT] [--install-dir DIR] [--dry-run]

选项：
  --port PORT        Node Port，默认 2222；必须与面板中的设置一致
  --install-dir DIR  安装目录，默认 /opt/remnanode
  --dry-run          只生成并检查配置，不安装或启动 Docker
  -h, --help         显示帮助

默认会安全地交互读取 SECRET_KEY，不在终端回显。
EOF
}

cleanup() {
  SECRET_KEY_VALUE=""
  unset REMNAWAVE_SECRET_KEY || true

  if [[ -n "$TEMP_ENV" && -e "$TEMP_ENV" ]]; then
    rm -f -- "$TEMP_ENV"
  fi
  if [[ -n "$TEMP_COMPOSE" && -e "$TEMP_COMPOSE" ]]; then
    rm -f -- "$TEMP_COMPOSE"
  fi
}

trap cleanup EXIT

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --port)
        (($# >= 2)) || die "--port 缺少端口值。"
        NODE_PORT="$2"
        shift 2
        ;;
      --install-dir)
        (($# >= 2)) || die "--install-dir 缺少目录值。"
        INSTALL_DIR="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "未知参数：$1"
        ;;
    esac
  done
}

validate_runtime() {
  [[ "$(uname -s)" == "Linux" || "$DRY_RUN" == "1" ]] || die "仅支持 Linux。"

  if [[ "$DRY_RUN" != "1" && "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "请登录 root 后运行此脚本。"
  fi

  [[ "$NODE_PORT" =~ ^[0-9]+$ ]] || die "Node Port 必须是数字。"
  ((NODE_PORT >= 1 && NODE_PORT <= 65535)) || die "Node Port 必须在 1-65535 之间。"

  [[ "$INSTALL_DIR" == /* ]] || die "安装目录必须是绝对路径。"
  [[ "$DRY_RUN" == "0" || "$DRY_RUN" == "1" ]] || die "REMNAWAVE_DRY_RUN 只能是 0 或 1。"

  COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
  ENV_FILE="${INSTALL_DIR}/.env"
}

normalize_secret_key() {
  SECRET_KEY_VALUE="${SECRET_KEY_VALUE//$'\r'/}"

  if [[ "$SECRET_KEY_VALUE" == SECRET_KEY=* ]]; then
    SECRET_KEY_VALUE="${SECRET_KEY_VALUE#SECRET_KEY=}"
  fi

  if ((${#SECRET_KEY_VALUE} >= 2)); then
    if [[ "$SECRET_KEY_VALUE" == \"*\" || "$SECRET_KEY_VALUE" == \'*\' ]]; then
      SECRET_KEY_VALUE="${SECRET_KEY_VALUE:1:${#SECRET_KEY_VALUE}-2}"
    fi
  fi
}

read_secret_key() {
  if [[ -z "$SECRET_KEY_VALUE" ]]; then
    [[ -r /dev/tty ]] || die "没有可用的交互终端，无法安全读取 SECRET_KEY。"

    printf '请粘贴 Remnawave 面板生成的 SECRET_KEY（输入不会显示）：' > /dev/tty
    if ! IFS= read -r -s SECRET_KEY_VALUE < /dev/tty; then
      printf '\n' > /dev/tty
      die "读取 SECRET_KEY 失败。"
    fi
    printf '\n' > /dev/tty
  fi

  normalize_secret_key

  ((${#SECRET_KEY_VALUE} >= 32)) || die "SECRET_KEY 长度异常，请重新从 Remnawave 面板复制。"
  [[ "$SECRET_KEY_VALUE" =~ ^[A-Za-z0-9._~+/=-]+$ ]] || die "SECRET_KEY 含有不支持的字符；请只粘贴密钥本身。"
}

docker_is_ready() {
  command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1
}

install_docker_debian() {
  local distro=""
  local codename=""
  local architecture=""

  # shellcheck disable=SC1091
  source /etc/os-release
  distro="${ID:-}"
  codename="${VERSION_CODENAME:-}"

  case "$distro" in
    debian|ubuntu) ;;
    *) die "当前仅自动支持 Debian/Ubuntu；检测到：${PRETTY_NAME:-$distro}" ;;
  esac

  [[ -n "$codename" ]] || die "无法识别系统代号 VERSION_CODENAME。"

  log "安装 Docker Engine 与 Docker Compose..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o DPkg::Lock::Timeout=120 update
  apt-get -o DPkg::Lock::Timeout=120 install -y ca-certificates curl

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${distro}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  architecture="$(dpkg --print-architecture)"
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
    "$architecture" "$distro" "$codename" > /etc/apt/sources.list.d/docker.list

  apt-get -o DPkg::Lock::Timeout=120 update
  apt-get -o DPkg::Lock::Timeout=120 install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

ensure_docker() {
  if docker_is_ready; then
    log "检测到 Docker 与 Docker Compose，跳过安装。"
  else
    command -v apt-get >/dev/null 2>&1 || die "找不到 apt-get；当前自动安装仅支持 Debian/Ubuntu。"
    install_docker_debian
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker
  else
    service docker start
  fi

  docker_is_ready || die "Docker 或 Docker Compose 安装后仍不可用。"
}

is_managed_install() {
  [[ -f "$COMPOSE_FILE" ]] && grep -Fqx "$MANAGED_MARKER" "$COMPOSE_FILE"
}

guard_existing_install() {
  if [[ -e "$COMPOSE_FILE" && ! -f "$COMPOSE_FILE" ]]; then
    die "$COMPOSE_FILE 已存在且不是普通文件。"
  fi

  if [[ -f "$COMPOSE_FILE" ]] && ! is_managed_install; then
    die "$COMPOSE_FILE 已存在但不是本脚本管理的配置；为防止覆盖，已停止。"
  fi

  if [[ ! -f "$COMPOSE_FILE" ]] && command -v docker >/dev/null 2>&1 && docker inspect remnanode >/dev/null 2>&1; then
    die "已存在名为 remnanode 的容器，但不是本脚本管理的安装；为防止冲突，已停止。"
  fi
}

port_is_listening() {
  command -v ss >/dev/null 2>&1 || return 1
  ss -H -lnt "sport = :${NODE_PORT}" 2>/dev/null | grep -q .
}

guard_node_port() {
  if ! is_managed_install && port_is_listening; then
    die "Node Port ${NODE_PORT} 已被其他程序占用。请在面板和脚本中改用同一个空闲端口。"
  fi
}

write_configuration() {
  install -d -m 700 "$INSTALL_DIR"
  TEMP_ENV="$(mktemp "${INSTALL_DIR}/.env.tmp.XXXXXX")"
  TEMP_COMPOSE="$(mktemp "${INSTALL_DIR}/docker-compose.yml.tmp.XXXXXX")"

  printf 'NODE_PORT=%s\nSECRET_KEY=%s\n' "$NODE_PORT" "$SECRET_KEY_VALUE" > "$TEMP_ENV"

  cat > "$TEMP_COMPOSE" <<'YAML'
# Managed by remnawave-node-installer.
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=${NODE_PORT:?NODE_PORT is required}
      - SECRET_KEY=${SECRET_KEY:?SECRET_KEY is required}
    logging:
      driver: json-file
      options:
        max-size: 10m
        max-file: "3"
YAML

  install -m 600 "$TEMP_ENV" "$ENV_FILE"
  install -m 600 "$TEMP_COMPOSE" "$COMPOSE_FILE"
  rm -f -- "$TEMP_ENV" "$TEMP_COMPOSE"
  TEMP_ENV=""
  TEMP_COMPOSE=""
}

validate_configuration() {
  [[ "$(stat -c '%a' "$INSTALL_DIR")" == "700" ]] || die "安装目录权限不是 700。"
  [[ "$(stat -c '%a' "$ENV_FILE")" == "600" ]] || die ".env 权限不是 600。"
  [[ "$(stat -c '%a' "$COMPOSE_FILE")" == "600" ]] || die "docker-compose.yml 权限不是 600。"

  if grep -Fq "$SECRET_KEY_VALUE" "$COMPOSE_FILE"; then
    die "安全检查失败：密钥不应直接出现在 docker-compose.yml。"
  fi

  if [[ "$DRY_RUN" != "1" ]]; then
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config --quiet
  fi
}

start_node() {
  log "拉取并启动 remnawave/node:latest..."
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" pull
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d --remove-orphans

  local _attempt=0
  local state=""
  for _attempt in {1..30}; do
    state="$(docker inspect -f '{{.State.Status}}' remnanode 2>/dev/null || true)"
    if [[ "$state" == "running" ]] && port_is_listening; then
      break
    fi
    sleep 2
  done

  state="$(docker inspect -f '{{.State.Status}}' remnanode 2>/dev/null || true)"
  [[ "$state" == "running" ]] || die "remnanode 容器未保持运行。请执行：docker logs --tail 100 remnanode"
  port_is_listening || die "容器正在运行，但 Node Port ${NODE_PORT} 尚未监听。请核对面板端口和密钥。"
}

print_result() {
  success "Remnawave Node 已安装并运行。"
  printf '\n'
  printf '  安装目录：%s\n' "$INSTALL_DIR"
  printf '  Node Port：%s/TCP\n' "$NODE_PORT"
  printf '  容器名称：remnanode\n'
  printf '  重启策略：always\n'
  printf '\n'
  printf '常用命令：\n'
  printf '  状态：docker compose --env-file %q -f %q ps\n' "$ENV_FILE" "$COMPOSE_FILE"
  printf '  日志：docker logs -f --tail 100 remnanode\n'
  printf '  更新：重新运行本一键脚本\n'
  printf '\n'
  warn "请确认云厂商安全组已放行 ${NODE_PORT}/TCP，并在 Remnawave 面板完成节点创建和配置文件绑定。"
}

main() {
  parse_args "$@"
  validate_runtime
  read_secret_key

  if [[ "$DRY_RUN" != "1" ]]; then
    ensure_docker
  else
    log "DRY-RUN：不会安装或启动 Docker。"
  fi

  guard_existing_install
  if [[ "$DRY_RUN" != "1" ]]; then
    guard_node_port
  fi
  write_configuration
  validate_configuration

  if [[ "$DRY_RUN" == "1" ]]; then
    success "DRY-RUN 配置生成与安全检查通过。"
    return 0
  fi

  start_node
  print_result
}

main "$@"
