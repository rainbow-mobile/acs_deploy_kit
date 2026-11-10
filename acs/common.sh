#!/bin/bash
# common.sh — 함수와 기본값만 정의한다. deploy.sh·update.sh·observer.sh·reset.sh가 읽는다.
# Muscat 키트(rainbow-deploy-kit/muscat)의 /etc/rainbow/muscat-env.conf·DEPLOY_ROOT 구성을 따른다.

# 설치 설정 파일. deploy.sh가 쓰고 observer(root)가 읽는다. 테스트·sudo 없는 PC는 ACS_ENV_FILE로 바꾼다.
ACS_ENV_FILE="${ACS_ENV_FILE:-/etc/rainbow/acs-env.conf}"
# 키트의 acs/ 폴더입니다. 다른 제품(fms·agent 등)은 키트 루트 아래 자기 폴더를 씁니다.
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
  ACS_ROOT="${ACS_ROOT:-$(dirname "$(dirname "$KIT_DIR")")/rb-acs}"
  # compose 프로젝트 이름. 컨테이너 이름이 <프로젝트>-<서비스>-1이 된다.
  ACS_PROJECT="${ACS_PROJECT:-rb-acs}"
  # 실행 중 Task 확인에 쓰는 Gateway 주소(호스트에서 접속).
  ACS_GATEWAY_URL="${ACS_GATEWAY_URL:-http://127.0.0.1:13000}"
  # 온라인 자동배포는 명시적으로 1을 설정한 현장만 사용한다. 버전 탭에서 켜고 끄면(deploy/auto-update.json) 그 값이 우선한다.
  ACS_ONLINE_AUTO_UPDATE="${ACS_ONLINE_AUTO_UPDATE:-0}"
  # 온라인 최신 버전 조회(버전 탭 표시). 인터넷이 없어도 짧게 실패하고 넘어간다. 네트워크를 아예 쓰지 않을 현장만 0.
  ACS_ONLINE_CHECK="${ACS_ONLINE_CHECK:-1}"
  # 온라인 최신 버전을 다시 조회하는 주기(초). 버전 탭 "다시 확인"은 바로 조회한다.
  ONLINE_CHECK_INTERVAL_SEC="${ONLINE_CHECK_INTERVAL_SEC:-300}"
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
  # 업데이트 실행 기록과 Common이 쓰는 설정(정책: 보관 개수)입니다.
  RUNS_DIR="$DEPLOY_DIR/runs"
  SETTINGS_FILE="$DEPLOY_DIR/settings.json"
  HEARTBEAT_FILE="$DEPLOY_DIR/observer.json"
  # 온라인 최신 버전(observer가 씀), 버전 탭 요청(Common이 씀: 다시 확인·온라인 업데이트), 버전 탭 자동 업데이트 설정(Common이 씀)입니다.
  ONLINE_FILE="$DEPLOY_DIR/online.json"
  REQUESTS_DIR="$DEPLOY_DIR/requests"
  AUTO_UPDATE_FILE="$DEPLOY_DIR/auto-update.json"
  UPDATE_LOG="$DEPLOY_DIR/update.log"
  # 서비스 관리 명령(acs) 링크 위치. deploy.sh와 observer(root)가 키트의 acs.sh로 연결한다.
  ACS_COMMAND_LINK="${ACS_COMMAND_LINK:-/usr/local/bin/acs}"
}

# acs 명령 링크를 이 키트의 acs.sh로 맞춘다. 이미 맞으면 아무것도 하지 않는다. 앞에 붙일 명령(sudo)을 인자로 받는다.
link_acs_command() {  # [sudo]
  local link_target="$KIT_DIR/acs.sh"
  [ "$(readlink -f "$ACS_COMMAND_LINK" 2>/dev/null)" = "$link_target" ] && return 0
  "$@" ln -sf "$link_target" "$ACS_COMMAND_LINK" 2>/dev/null
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

# curl이 있으면 사용하고, 최소 설치 현장에서는 Python 표준 라이브러리로 내려받는다.
# 다운로드 경과를 출력하는 간격(초)입니다.
DOWNLOAD_PROGRESS_INTERVAL_SEC="${DOWNLOAD_PROGRESS_INTERVAL_SEC:-3}"

format_duration() {  # <초>
  if [ "$1" -ge 60 ]; then printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); else printf '%ds' "$1"; fi
}

download_file() {  # <url> <output> <timeout_sec> [progress]
  # progress(1)를 주면 큰 ZIP처럼 오래 걸리는 다운로드의 받은 양·속도·경과·남은 시간을 몇 초마다 한 줄씩 출력한다.
  # curl 진행 막대는 observer 로그에 제어 문자로 남으므로, curl은 조용히 돌리고 받은 파일 크기를 읽어 줄 단위로 찍는다.
  # 중간에 실패하거나 Ctrl+C·종료 신호를 받으면 받던 파일을 지운다.
  if ! command -v curl >/dev/null 2>&1; then
    release_tool download "$1" "$2" "$3" "${4:-0}"
    return
  fi
  if [ "${4:-0}" != "1" ]; then
    curl -fsS --max-time "$3" -H "Cache-Control: no-cache" -o "$2" "$1"
    return
  fi
  local total_bytes download_pid download_status started_at received_bytes elapsed_seconds speed_bytes file_label progress_line
  file_label="$(basename "$1")"
  total_bytes="$(curl -fsSI --max-time 15 -H "Cache-Control: no-cache" "$1" 2>/dev/null \
    | tr -d '\r' | awk 'tolower($1) == "content-length:" { size = $2 } END { print size + 0 }')"
  rm -f "$2"
  curl -fsS --max-time "$3" -H "Cache-Control: no-cache" -o "$2" "$1" &
  download_pid=$!
  # set -e 아래에서도 끝까지 지우도록 각 명령 실패를 무시하고, 값은 지금 풀어 둡니다.
  trap "kill $download_pid 2>/dev/null || true; wait $download_pid 2>/dev/null || true; rm -f $(printf '%q' "$2"); exit 130" INT TERM
  started_at=$SECONDS
  while kill -0 "$download_pid" 2>/dev/null; do
    sleep "$DOWNLOAD_PROGRESS_INTERVAL_SEC"
    kill -0 "$download_pid" 2>/dev/null || break
    received_bytes="$(stat -c %s "$2" 2>/dev/null || echo 0)"
    elapsed_seconds=$((SECONDS - started_at))
    speed_bytes=$((received_bytes / (elapsed_seconds > 0 ? elapsed_seconds : 1)))
    progress_line="   📥 $file_label $((received_bytes / 1048576))"
    if [ "$total_bytes" -gt 0 ]; then
      progress_line="$progress_line/$((total_bytes / 1048576))MB $((received_bytes * 100 / total_bytes))%"
      [ "$speed_bytes" -gt 0 ] && progress_line="$progress_line · 남은 시간 약 $(format_duration $(((total_bytes - received_bytes) / speed_bytes)))"
    else
      progress_line="${progress_line}MB"
    fi
    echo "$progress_line · $((speed_bytes / 1048576))MB/s · 경과 $(format_duration "$elapsed_seconds")"
  done
  download_status=0
  wait "$download_pid" || download_status=$?
  trap - INT TERM
  if [ "$download_status" -ne 0 ]; then
    rm -f "$2"
    return "$download_status"
  fi
  echo "   📥 $file_label 완료 $(($(stat -c %s "$2" 2>/dev/null || echo 0) / 1048576))MB · 걸린 시간 $(format_duration $((SECONDS - started_at)))"
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
  # 이번 업데이트 실행 기록(deploy/runs/<run_id>.json)에도 단계 진행을 남긴다. Debugger 버전 탭 이력이 읽는다.
  [ -n "${RUN_FILE:-}" ] && release_tool run-stage "$RUN_FILE" "$1" "$2" "$3" "${5:-${CURRENT_VERSION:-}}" || true
}

# 경고를 로그와 실행 기록에 함께 남긴다.
warn() {  # <message>
  log "⚠️  $1"
  [ -n "${RUN_FILE:-}" ] && release_tool run-note "$RUN_FILE" warning "${CURRENT_STAGE:-}" "$1" || true
}

# 에러를 실행 기록에 남긴다(로그는 부르는 쪽이 남김).
note_error() {  # <message>
  [ -n "${RUN_FILE:-}" ] && release_tool run-note "$RUN_FILE" error "${CURRENT_STAGE:-}" "$1" || true
}

new_run_id() {
  echo "$(date '+%Y%m%d-%H%M%S')-$$"
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
  local executions_json temporary_directory
  if ! command -v curl >/dev/null 2>&1; then
    temporary_directory="$(mktemp -d)" || { echo "unknown"; return; }
    if download_file "$ACS_GATEWAY_URL/task/execution/executions" "$temporary_directory/executions.json" 5 2>/dev/null; then
      release_tool count-active < "$temporary_directory/executions.json" 2>/dev/null || echo "unknown"
    else
      echo "unknown"
    fi
    rm -f "$temporary_directory/executions.json" "$temporary_directory/.executions.json.part"
    rmdir "$temporary_directory"
    return
  fi
  if executions_json="$(curl -fsS --max-time 5 "$ACS_GATEWAY_URL/task/execution/executions" 2>/dev/null)"; then
    printf '%s' "$executions_json" | release_tool count-active 2>/dev/null || echo "unknown"
  else
    echo "unknown"
  fi
}

waiting_message() {  # <active_count>
  echo "실행 중인 Task $1개가 끝나면 업데이트합니다. 바로 적용하려면 강제 적용을 누르세요."
}
