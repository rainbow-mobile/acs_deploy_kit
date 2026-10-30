#!/bin/bash
# deploy.sh — 현장 PC에 ACS를 처음 설치하고, 부팅 때 자동으로 뜨도록 등록한다.
# 사용법: ./deploy.sh <acs-<버전>.zip> [옵션]
#   릴리즈 ZIP은 rb_acs에서 `make backend.deploy`로 만든다(최초 설치는 이미지 포함을 고른 ZIP).
#
#   --root=<디렉터리>        설치 디렉터리 (기본: 배포 키트 옆 rb-acs, 예: ~/rb-acs)
#   --project=<이름>         compose 프로젝트 이름 (기본: rb-acs)
#   --gateway-url=<주소>     호스트에서 Gateway 주소 (기본: http://127.0.0.1:13000). 실행 중 Task 확인에 쓴다
#   --site-env=<파일>        현장 설정(site.env)으로 복사할 파일. 없으면 ZIP의 예시로 만들고 DB 비밀번호를 무작위로 채운다
#   --frs-url=<주소>         site.env를 새로 만들 때 넣을 FRS REST 주소(http://host:port)
#   --moms-url=<주소>        site.env를 새로 만들 때 넣을 SMC MOMS 주소
#   --site-compose=<파일>    현장 compose 덮어쓰기(compose.site.yml, 포트 변경 등). 업데이트해도 바뀌지 않는다
#   --no-systemd             observer systemd 등록과 docker 부팅 자동 시작을 건너뛴다(시험용, sudo 없는 PC)
#
# 하는 일(Muscat muscat-deploy.sh 순서를 따른다):
#   1. arch·필수 명령 확인. docker가 없고 인터넷이 되면 apt로 설치를 시도한다
#   2. 설정 파일(/etc/rainbow/acs-env.conf)에 설치 디렉터리·프로젝트·Gateway 주소를 적는다(observer가 root로 읽음)
#   3. site.env 준비 → acs-update.sh --install로 이미지 load·설정·서비스 bin 배치·compose up·헬스체크
#   4. docker 부팅 자동 시작(compose restart: unless-stopped로 컨테이너도 함께 뜬다)과 observer systemd 등록

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

PACKAGE_PATH=""
OPTION_ROOT=""
OPTION_PROJECT=""
OPTION_GATEWAY_URL=""
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
[ -n "$PACKAGE_PATH" ] && [ -f "$PACKAGE_PATH" ] || { echo "❌ 릴리즈 ZIP을 지정하세요." >&2; usage; exit 2; }
PACKAGE_PATH="$(cd "$(dirname "$PACKAGE_PATH")" && pwd)/$(basename "$PACKAGE_PATH")"

# 다시 설치할 때는 기존 설정 파일 값을 이어 쓰고, 옵션으로 준 값만 바꾼다.
load_acs_env
ACS_ROOT="${OPTION_ROOT:-$ACS_ROOT}"
ACS_PROJECT="${OPTION_PROJECT:-$ACS_PROJECT}"
ACS_GATEWAY_URL="${OPTION_GATEWAY_URL:-$ACS_GATEWAY_URL}"
mkdir -p "$ACS_ROOT"
ACS_ROOT="$(cd "$ACS_ROOT" && pwd)"

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
  curl -fsS --max-time 5 -o /dev/null https://download.docker.com 2>/dev/null
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
for required_command in python3 curl flock; do
  command -v "$required_command" >/dev/null 2>&1 || { echo "❌ 필수 명령이 없습니다: $required_command" >&2; exit 1; }
done
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
# RB ACS 설치 설정(deploy.sh가 씀). acs-observer.sh(root)·acs-update.sh·acs-ctl.sh가 읽는다.
# 설치 디렉터리: compose·서비스 bin·deploy/(업데이트 디렉터리)·backups/
ACS_ROOT="$ACS_ROOT"
# compose 프로젝트 이름(컨테이너 이름 <프로젝트>-<서비스>-1)
ACS_PROJECT="$ACS_PROJECT"
# 호스트에서 Gateway 주소. 업데이트 전 실행 중 Task 확인에 쓴다
ACS_GATEWAY_URL="$ACS_GATEWAY_URL"
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

bash "$SCRIPT_DIR/acs-update.sh" --install "$PACKAGE_PATH"

# ── 4. 자동 실행 등록 ─────────────────────────────
if [ "$REGISTER_SYSTEMD" -eq 1 ]; then
  # 컨테이너는 compose restart: unless-stopped라 docker만 부팅 때 뜨면 함께 올라온다.
  sudo systemctl enable docker >/dev/null 2>&1 || echo "⚠️  docker 부팅 자동 시작을 켜지 못했습니다."
  sed -e "s#@KIT_DIR@#$SCRIPT_DIR#g" -e "s#@ACS_ENV_FILE@#$ACS_ENV_FILE#g" "$SCRIPT_DIR/systemd/$OBSERVER_SERVICE_NAME.service" \
    | sudo tee "/etc/systemd/system/$OBSERVER_SERVICE_NAME.service" > /dev/null
  sudo systemctl daemon-reload
  sudo systemctl enable "$OBSERVER_SERVICE_NAME" >/dev/null
  sudo systemctl restart "$OBSERVER_SERVICE_NAME"
  echo "✅ $OBSERVER_SERVICE_NAME 서비스 등록 완료(로그: journalctl -u $OBSERVER_SERVICE_NAME -f)"
else
  echo "ℹ️  --no-systemd: observer를 등록하지 않았습니다. 직접 실행: ACS_ENV_FILE=$ACS_ENV_FILE bash $SCRIPT_DIR/acs-observer.sh"
fi

echo ""
echo "╔══════════════════════════════════╗"
echo "║   RB ACS 설치 완료 ✅            ║"
echo "╚══════════════════════════════════╝"
echo "  버전: $(release_tool installed-get "$INSTALLED_FILE" version)"
echo "  Debugger: $ACS_GATEWAY_URL/state/debugger/  (버전 탭에서 업데이트 ZIP 업로드)"
echo "  상태 확인: $SCRIPT_DIR/acs-ctl.sh status"
