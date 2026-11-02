#!/bin/bash
# common.sh — 함수와 기본값만 정의한다. deploy.sh·update.sh·observer.sh·reset.sh가 읽는다.
# Muscat 키트(rainbow-deploy-kit/muscat)의 /etc/rainbow/muscat-env.conf·DEPLOY_ROOT 구성을 따른다.

# 설치 설정 파일. deploy.sh가 쓰고 observer(root)가 읽는다. 테스트·sudo 없는 PC는 ACS_ENV_FILE로 바꾼다.
ACS_ENV_FILE="${ACS_ENV_FILE:-/etc/rainbow/acs-env.conf}"
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_TOOL="$KIT_DIR/release.py"
DEFAULT_RELEASE_ORIGIN="https://diokjo4dtg1mp.cloudfront.net/acs"

# 설정 파일 값을 읽는다. 없으면 기본값을 쓴다(deploy.sh 최초 실행 전).
load_acs_env() {
  if [ -f "$ACS_ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ACS_ENV_FILE"
  fi
  # 설치 디렉터리. compose·서비스 bin·deploy/가 여기 있다(Muscat DEPLOY_ROOT와 같은 역할).
  ACS_ROOT="${ACS_ROOT:-$(dirname "$KIT_DIR")/rb-acs}"
  # compose 프로젝트 이름. 컨테이너 이름이 <프로젝트>-<서비스>-1이 된다.
  ACS_PROJECT="${ACS_PROJECT:-rb-acs}"
  # 실행 중 Task 확인에 쓰는 Gateway 주소(호스트에서 접속).
  ACS_GATEWAY_URL="${ACS_GATEWAY_URL:-http://127.0.0.1:13000}"
  # 온라인 자동배포는 명시적으로 1을 설정한 현장만 사용한다.
  ACS_ONLINE_AUTO_UPDATE="${ACS_ONLINE_AUTO_UPDATE:-0}"
  ACS_RELEASE_CHANNEL="${ACS_RELEASE_CHANNEL:-main}"
  # rb_acs가 latest.json을 올린 S3/CloudFront 공개 URL(prefix 루트).
  ACS_RELEASE_BASE_URL="${ACS_RELEASE_BASE_URL:-$DEFAULT_RELEASE_ORIGIN/$ACS_RELEASE_CHANNEL}"
  ACS_RELEASE_BASE_URL="${ACS_RELEASE_BASE_URL%/}"
  # observer 확인 주기(초). 업로드 ZIP은 inotify로 바로 감지하고, 없으면 이 주기로 확인한다.
  CHECK_INTERVAL_SEC="${CHECK_INTERVAL_SEC:-5}"
  # 업데이트 후 서비스가 healthy가 되기를 기다리는 최대 시간(초).
  HEALTH_TIMEOUT_SEC="${HEALTH_TIMEOUT_SEC:-180}"
  # 남겨 둘 DB 백업 개수.
  BACKUP_KEEP="${BACKUP_KEEP:-3}"
  DEPLOY_DIR="$ACS_ROOT/deploy"
  OBSERVE_DIR="$DEPLOY_DIR/observe"
  STATUS_FILE="$DEPLOY_DIR/status.json"
  INSTALLED_FILE="$DEPLOY_DIR/installed.json"
  HEARTBEAT_FILE="$DEPLOY_DIR/observer.json"
  UPDATE_LOG="$DEPLOY_DIR/update.log"
}

# 이 PC arch를 릴리즈 arch 이름으로 바꾼다. 서비스 bin은 지금 amd64만 있다.
host_arch() {
  case "$(uname -m)" in
    x86_64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) uname -m ;;
  esac
}

release_tool() {
  python3 -I "$RELEASE_TOOL" "$@"
}

# 설치 디렉터리에서 ACS compose를 실행한다. 현장 덮어쓰기 compose.site.yml(포트 변경 등)이 있으면 마지막에 얹는다.
# --env-file을 하나라도 주면 .env를 자동으로 읽지 않으므로 .env와 site.env를 모두 적는다.
acs_compose() {
  local compose_files=(-f "$ACS_ROOT/compose.yml" -f "$ACS_ROOT/compose.offline.yml")
  [ -f "$ACS_ROOT/compose.site.yml" ] && compose_files+=(-f "$ACS_ROOT/compose.site.yml")
  docker compose -p "$ACS_PROJECT" --project-directory "$ACS_ROOT" \
    --env-file "$ACS_ROOT/.env" --env-file "$ACS_ROOT/site.env" \
    "${compose_files[@]}" "$@"
}

# compose가 띄우는 ACS 서비스(bin 서비스). compose.offline.yml에서 ./services/<이름>을 마운트하는 서비스와 같다.
ACS_SERVICES=(common scenario task state external map mock)

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# status.json을 쓴다. Common이 읽어 Debugger 버전 탭으로 보낸다.
write_status() {  # <state> <stage> <message> [package] [version]
  release_tool write-status "$STATUS_FILE" "$1" "$2" "$3" "${4:-${CURRENT_PACKAGE:-}}" "${5:-${CURRENT_VERSION:-}}" || true
}

# observer heartbeat. 업데이트 엔진도 오래 걸리는 단계마다 갱신해 화면이 observer를 멈춘 것으로 보지 않게 한다.
write_heartbeat() {
  release_tool write-heartbeat "$HEARTBEAT_FILE" "$CHECK_INTERVAL_SEC" || true
}

# 서비스 컨테이너 health 상태. healthcheck가 없으면 running 여부로 대신한다.
service_health() {  # <service>
  local container_id
  container_id="$(acs_compose ps -q "$1" 2>/dev/null | head -n1)"
  [ -n "$container_id" ] || { echo "missing"; return; }
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id" 2>/dev/null || echo "missing"
}

# 서비스들이 healthy(또는 healthcheck 없는 running)가 될 때까지 기다린다.
wait_services_healthy() {  # <timeout_sec> <service...>
  local timeout_sec=$1; shift
  local deadline=$((SECONDS + timeout_sec))
  local service_name health pending
  while :; do
    pending=()
    for service_name in "$@"; do
      health="$(service_health "$service_name")"
      case "$health" in
        healthy|running) ;;
        *) pending+=("$service_name:$health") ;;
      esac
    done
    [ ${#pending[@]} -eq 0 ] && return 0
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "${pending[*]}"
      return 1
    fi
    write_heartbeat
    sleep 3
  done
}

# 끝나지 않은 Task 실행 수. Task 서비스가 응답하지 않으면 unknown(설치 전·서비스가 내려가 있음)을 출력한다.
active_task_count() {
  local executions_json
  if executions_json="$(curl -fsS --max-time 5 "$ACS_GATEWAY_URL/task/execution/executions" 2>/dev/null)"; then
    printf '%s' "$executions_json" | release_tool count-active 2>/dev/null || echo "unknown"
  else
    echo "unknown"
  fi
}

waiting_message() {  # <active_count>
  echo "실행 중인 Task $1개가 끝나면 업데이트합니다. 바로 적용하려면 강제 적용을 누르세요."
}
