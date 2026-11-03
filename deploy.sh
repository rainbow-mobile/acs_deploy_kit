#!/bin/bash
# deploy.sh — 현장 PC에 ACS를 처음 설치하고, 부팅 때 자동으로 뜨도록 등록한다.
# 사용법: ./deploy.sh <acs-<버전>.zip> [옵션] | ./deploy.sh --online [옵션]
#   릴리즈 ZIP은 rb_acs에서 `make backend.deploy`로 만든다(최초 설치는 이미지 포함을 고른 ZIP).
#   --online                 S3/CloudFront의 최신 설치용 ZIP을 내려받아 최초 설치
#
#   --root=<디렉터리>        설치 디렉터리 (기본: 배포 키트 옆 rb-acs, 예: ~/rb-acs)
#   --project=<이름>         compose 프로젝트 이름 (기본: rb-acs)
#   --gateway-url=<주소>     호스트에서 Gateway 주소 (기본: http://127.0.0.1:13000). 실행 중 Task 확인에 쓴다
#   --site-env=<파일>        현장 설정(site.env)으로 복사할 파일. 없으면 ZIP의 예시로 만들고 DB 비밀번호를 무작위로 채운다
#   --frs-url=<주소>         site.env를 새로 만들 때 넣을 FRS REST 주소(http://host:port)
#   --moms-url=<주소>        site.env를 새로 만들 때 넣을 SMC MOMS 주소
#   --site-compose=<파일>    현장 compose 덮어쓰기(compose.site.yml, 포트 변경 등). 업데이트해도 바뀌지 않는다
#   --online-url=<주소>      latest.json이 있는 S3/CloudFront 공개 URL
#   --online-channel=<이름>  온라인 배포 채널 (기본: main, URL은 .../acs/<채널>)
#   --auto-update            온라인 최신 릴리즈 자동 적용(기본값: 사용 안 함)
#   --no-auto-update         온라인 자동 적용 끄기(기존 설정도 해제)
#   --no-systemd             observer systemd 등록과 docker 부팅 자동 시작을 건너뛴다(시험용, sudo 없는 PC)
#
# 하는 일(Muscat muscat-deploy.sh 순서를 따른다):
#   1. arch·필수 명령 확인. docker가 없고 인터넷이 되면 apt로 설치를 시도한다
#   2. 설정 파일(/etc/rainbow/acs-env.conf)에 설치 디렉터리·프로젝트·Gateway 주소를 적는다(observer가 root로 읽음)
#   3. site.env 준비 → update.sh --install로 이미지 load·설정·서비스 bin 배치·compose up·헬스체크
#   4. docker 부팅 자동 시작(compose restart: unless-stopped로 컨테이너도 함께 뜬다)과 observer systemd 등록

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

PACKAGE_PATH=""
ONLINE_INSTALL=0
ONLINE_PACKAGE_PATH=""
OPTION_ROOT=""
OPTION_PROJECT=""
OPTION_GATEWAY_URL=""
OPTION_ONLINE_URL=""
OPTION_ONLINE_CHANNEL=""
OPTION_AUTO_UPDATE=""
SITE_ENV_SOURCE=""
SITE_COMPOSE_SOURCE=""
FRS_URL=""
MOMS_URL=""
REGISTER_SYSTEMD=1
OBSERVER_SERVICE_NAME="acs-update-observer"

usage() { sed -n '2,20p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --root=*) OPTION_ROOT="${1#*=}" ;;
    --project=*) OPTION_PROJECT="${1#*=}" ;;
    --gateway-url=*) OPTION_GATEWAY_URL="${1#*=}" ;;
    --online) ONLINE_INSTALL=1 ;;
    --online-url=*) OPTION_ONLINE_URL="${1#*=}" ;;
    --online-channel=*) OPTION_ONLINE_CHANNEL="${1#*=}" ;;
    --auto-update) OPTION_AUTO_UPDATE=1 ;;
    --no-auto-update) OPTION_AUTO_UPDATE=0 ;;
    --site-env=*) SITE_ENV_SOURCE="${1#*=}" ;;
    --site-compose=*) SITE_COMPOSE_SOURCE="${1#*=}" ;;
    --frs-url=*) FRS_URL="${1#*=}" ;;
    --moms-url=*) MOMS_URL="${1#*=}" ;;
    --no-systemd) REGISTER_SYSTEMD=0 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "❌ 알 수 없는 옵션: $1" >&2; usage; exit 2 ;;
    *) PACKAGE_PATH="$1" ;;
  esac
  shift
done
[ "$ONLINE_INSTALL" -eq 0 ] || [ -z "$PACKAGE_PATH" ] || { echo "❌ --online에는 로컬 ZIP을 함께 지정할 수 없습니다." >&2; exit 2; }
for required_command in python3 flock sha256sum; do
  command -v "$required_command" >/dev/null 2>&1 || { echo "❌ 필수 명령이 없습니다: $required_command" >&2; exit 1; }
done

# 다시 설치할 때는 기존 설정 파일 값을 이어 쓰고, 옵션으로 준 값만 바꾼다.
load_acs_env
ACS_ROOT="${OPTION_ROOT:-$ACS_ROOT}"
ACS_PROJECT="${OPTION_PROJECT:-$ACS_PROJECT}"
ACS_GATEWAY_URL="${OPTION_GATEWAY_URL:-$ACS_GATEWAY_URL}"
ACS_RELEASE_CHANNEL="${OPTION_ONLINE_CHANNEL:-$ACS_RELEASE_CHANNEL}"
if [ -n "$OPTION_ONLINE_URL" ]; then
  ACS_RELEASE_BASE_URL="$OPTION_ONLINE_URL"
elif [ -n "$OPTION_ONLINE_CHANNEL" ]; then
  ACS_RELEASE_BASE_URL="$DEFAULT_RELEASE_ORIGIN/$ACS_RELEASE_CHANNEL"
fi
ACS_RELEASE_BASE_URL="${ACS_RELEASE_BASE_URL%/}"
ACS_ONLINE_AUTO_UPDATE="${OPTION_AUTO_UPDATE:-$ACS_ONLINE_AUTO_UPDATE}"
if [ "$ACS_ONLINE_AUTO_UPDATE" = "1" ] && [ -z "$ACS_RELEASE_BASE_URL" ]; then
  echo "❌ --auto-update에는 --online-url=<S3/CloudFront URL>이 필요합니다." >&2
  exit 2
fi
mkdir -p "$ACS_ROOT"
ACS_ROOT="$(cd "$ACS_ROOT" && pwd)"

download_online_install() {
  local manifest_path expected_sha actual_sha relative_path
  manifest_path="$(mktemp /tmp/acs-online-latest.XXXXXX.json)"
  ONLINE_PACKAGE_PATH="$(mktemp /tmp/acs-online-install.XXXXXX.zip)"
  echo "🌐 온라인 최신 설치 릴리즈 확인: $ACS_RELEASE_BASE_URL/latest.json"
  download_file "$ACS_RELEASE_BASE_URL/latest.json" "$manifest_path" 15 \
    || { rm -f "$manifest_path" "$ONLINE_PACKAGE_PATH"; echo "❌ latest.json을 받지 못했습니다." >&2; return 1; }
  [ "$(release_tool json-get "$manifest_path" kind)" = "acs.online-release" ] \
    || { rm -f "$manifest_path" "$ONLINE_PACKAGE_PATH"; echo "❌ 온라인 매니페스트 형식이 올바르지 않습니다." >&2; return 1; }
  relative_path="$(release_tool json-get "$manifest_path" deploy.path)"
  expected_sha="$(release_tool json-get "$manifest_path" deploy.sha256)"
  case "$relative_path" in
    ""|/*|*".."*) rm -f "$manifest_path" "$ONLINE_PACKAGE_PATH"; echo "❌ 온라인 설치 경로가 올바르지 않습니다." >&2; return 1 ;;
  esac
  [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] \
    || { rm -f "$manifest_path" "$ONLINE_PACKAGE_PATH"; echo "❌ 온라인 설치 sha256이 올바르지 않습니다." >&2; return 1; }
  download_file "$ACS_RELEASE_BASE_URL/$relative_path" "$ONLINE_PACKAGE_PATH" 1800 \
    || { rm -f "$manifest_path" "$ONLINE_PACKAGE_PATH"; echo "❌ 온라인 설치 ZIP을 받지 못했습니다." >&2; return 1; }
  actual_sha="$(sha256sum "$ONLINE_PACKAGE_PATH" | cut -d' ' -f1)"
  rm -f "$manifest_path"
  [ "$actual_sha" = "$expected_sha" ] \
    || { rm -f "$ONLINE_PACKAGE_PATH"; echo "❌ 온라인 설치 ZIP sha256이 맞지 않습니다." >&2; return 1; }
  PACKAGE_PATH="$ONLINE_PACKAGE_PATH"
  echo "📥 온라인 설치 ZIP 다운로드 완료: $(basename "$relative_path")"
}

if [ "$ONLINE_INSTALL" -eq 1 ]; then
  download_online_install || exit 1
  trap 'rm -f "$ONLINE_PACKAGE_PATH"' EXIT
else
  [ -n "$PACKAGE_PATH" ] && [ -f "$PACKAGE_PATH" ] || { echo "❌ 릴리즈 ZIP을 지정하거나 --online을 사용하세요." >&2; usage; exit 2; }
  PACKAGE_PATH="$(cd "$(dirname "$PACKAGE_PATH")" && pwd)/$(basename "$PACKAGE_PATH")"
fi

echo ""
echo "╔══════════════════════════════════╗"
echo "║   RB ACS 설치 시작               ║"
echo "╚══════════════════════════════════╝"
echo "📦 릴리즈: $PACKAGE_PATH"
echo "📁 설치 디렉터리: $ACS_ROOT (프로젝트 $ACS_PROJECT)"

# ── 1. arch·필수 명령 ─────────────────────────────
if [ "$(host_arch)" != "amd64" ]; then
  echo "❌ 지원하지 않는 아키텍처입니다: $(uname -m). ACS 서비스 bin은 amd64(x86_64)만 있습니다." >&2
  exit 1
fi

can_use_network() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 5 -o /dev/null https://download.docker.com 2>/dev/null
  else
    python3 -I -c 'from urllib.request import urlopen; urlopen("https://download.docker.com", timeout=5).close()' 2>/dev/null
  fi
}

# Muscat ensure_docker와 같다. 오프라인 현장은 Docker를 미리 설치해 와야 한다.
ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1 && can_use_network; then
    echo "🐳 Docker 설치 시도(apt)..."
    sudo apt-get update -qq && sudo apt-get install -y docker.io docker-compose-v2 >/dev/null || true
  fi
  if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    echo "❌ Docker와 Docker Compose(v2.24 이상)가 필요합니다. 인터넷이 없으면 docker.io·docker-compose-v2 패키지를 미리 설치하세요." >&2
    exit 1
  fi
}

# compose.offline.yml의 !reset·!override 태그는 Compose v2.24부터 지원한다.
check_compose_version() {
  local compose_version
  compose_version="$(docker compose version --short 2>/dev/null | sed 's/^v//')"
  if ! printf '2.24.0\n%s\n' "$compose_version" | sort -V -C; then
    echo "❌ Docker Compose v2.24 이상이 필요합니다(현재 $compose_version)." >&2
    exit 1
  fi
}

ensure_docker_permission() {
  docker info >/dev/null 2>&1 && return 0
  echo "⚠️  현재 사용자($USER)가 docker를 쓸 수 없습니다. docker 그룹에 추가합니다."
  sudo usermod -aG docker "$USER"
  echo "❌ 다시 로그인한 뒤 deploy.sh를 다시 실행하세요." >&2
  exit 1
}

ensure_docker
check_compose_version
ensure_docker_permission
if ! command -v inotifywait >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1 && can_use_network; then
    sudo apt-get install -y inotify-tools >/dev/null 2>&1 || true
  fi
  command -v inotifywait >/dev/null 2>&1 || echo "ℹ️  inotify-tools가 없어 observer가 ${CHECK_INTERVAL_SEC}초마다 확인합니다."
fi

# ── 2. 설정 파일 ──────────────────────────────────
write_env_file() {
  local env_content
  env_content="$(cat <<EOF
# RB ACS 설치 설정(deploy.sh가 씀). observer.sh(root)·update.sh·reset.sh가 읽는다.
# 설치 디렉터리: compose·서비스 bin·deploy/(업데이트 디렉터리)·backups/
ACS_ROOT="$ACS_ROOT"
# compose 프로젝트 이름(컨테이너 이름 <프로젝트>-<서비스>-1)
ACS_PROJECT="$ACS_PROJECT"
# 호스트에서 Gateway 주소. 업데이트 전 실행 중 Task 확인에 쓴다
ACS_GATEWAY_URL="$ACS_GATEWAY_URL"
# 온라인 자동배포. 기본은 0이며 1일 때만 observer가 네트워크를 조회한다
ACS_ONLINE_AUTO_UPDATE="$ACS_ONLINE_AUTO_UPDATE"
ACS_RELEASE_CHANNEL="$ACS_RELEASE_CHANNEL"
ACS_RELEASE_BASE_URL="$ACS_RELEASE_BASE_URL"
EOF
)"
  mkdir -p "$(dirname "$ACS_ENV_FILE")" 2>/dev/null || true
  if [ -w "$(dirname "$ACS_ENV_FILE")" ]; then
    printf '%s\n' "$env_content" > "$ACS_ENV_FILE"
  else
    sudo mkdir -p "$(dirname "$ACS_ENV_FILE")"
    printf '%s\n' "$env_content" | sudo tee "$ACS_ENV_FILE" > /dev/null
  fi
  echo "📝 설정 파일: $ACS_ENV_FILE"
}
write_env_file
load_acs_env

# ── 3. site.env·설치 ──────────────────────────────
if [ -n "$SITE_COMPOSE_SOURCE" ]; then
  cp "$SITE_COMPOSE_SOURCE" "$ACS_ROOT/compose.site.yml"
  echo "📝 현장 compose 덮어쓰기: $ACS_ROOT/compose.site.yml"
fi
if [ -n "$SITE_ENV_SOURCE" ]; then
  install -m 600 "$SITE_ENV_SOURCE" "$ACS_ROOT/site.env"
  echo "📝 site.env 복사: $SITE_ENV_SOURCE"
elif [ ! -f "$ACS_ROOT/site.env" ]; then
  release_tool make-site-env "$PACKAGE_PATH" "$ACS_ROOT/site.env" "$FRS_URL" "$MOMS_URL"
  echo "📝 site.env를 만들었습니다(DB 비밀번호는 무작위). FRS·MOMS 주소를 확인하세요: $ACS_ROOT/site.env"
else
  echo "📝 기존 site.env를 그대로 씁니다."
fi

bash "$SCRIPT_DIR/update.sh" --install "$PACKAGE_PATH"

# ── 4. 자동 실행 등록 ─────────────────────────────
if [ "$REGISTER_SYSTEMD" -eq 1 ]; then
  # 컨테이너는 compose restart: unless-stopped라 docker만 부팅 때 뜨면 함께 올라온다.
  sudo systemctl enable docker >/dev/null 2>&1 || echo "⚠️  docker 부팅 자동 시작을 켜지 못했습니다."
  sudo tee "/etc/systemd/system/$OBSERVER_SERVICE_NAME.service" > /dev/null <<EOF
[Unit]
Description=RB ACS Update Observer
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
WorkingDirectory=$SCRIPT_DIR
Environment=ACS_ENV_FILE=$ACS_ENV_FILE
ExecStart=/bin/bash $SCRIPT_DIR/observer.sh
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable "$OBSERVER_SERVICE_NAME" >/dev/null
  sudo systemctl restart "$OBSERVER_SERVICE_NAME"
  echo "✅ $OBSERVER_SERVICE_NAME 서비스 등록 완료(로그: journalctl -u $OBSERVER_SERVICE_NAME -f)"
else
  echo "ℹ️  --no-systemd: observer를 등록하지 않았습니다. 직접 실행: ACS_ENV_FILE=$ACS_ENV_FILE bash $SCRIPT_DIR/observer.sh"
fi

echo ""
echo "╔══════════════════════════════════╗"
echo "║   RB ACS 설치 완료 ✅            ║"
echo "╚══════════════════════════════════╝"
echo "  버전: $(release_tool installed-get "$INSTALLED_FILE" version)"
echo "  Debugger: $ACS_GATEWAY_URL/state/debugger/  (버전 탭에서 업데이트 ZIP 업로드)"
echo "  온라인 자동배포: $([ "$ACS_ONLINE_AUTO_UPDATE" = "1" ] && echo 사용 || echo 사용 안 함)"
echo "  상태 파일: $STATUS_FILE"
