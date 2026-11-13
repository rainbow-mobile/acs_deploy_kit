#!/bin/bash
# acs.sh — 설치한 ACS 서비스를 보고 실행·중지·재시작·로그를 보는 명령. deploy.sh가 /usr/local/bin/acs로 연결한다.
# 사용법: acs [status|start|stop|restart|logs|version|observer] [서비스...] [--force]
#   status (기본)        서비스 상태(compose ps)·설치 버전·업데이트 상태·observer 상태
#   start [서비스...]    실행(compose up -d). 서비스를 주지 않으면 전체
#   stop [서비스...]     중지. 서비스를 주지 않으면 전체
#   restart [서비스...]  재시작. 서비스를 주지 않으면 전체
#   logs [서비스...]     로그를 마지막 200줄부터 따라가며 본다(Ctrl+C로 끝)
#   version              설치된 전체·서비스별 버전
#   observer [status|restart|logs]  업데이트 감시(systemd acs-update-observer)
#   --force              업데이트 중이어도 start·stop·restart를 한다(업데이트 엔진의 헬스체크·되돌리기와 겹칠 수 있음)
# 서비스: common scenario task state external map mock api-gateway zenoh-router keycloak mongo postgres
# 종료 코드: 0 성공, 2 사용법 오류, 75 업데이트 중이라 거절, 그 밖은 docker compose 종료 코드.
# compose 파일·env 파일·프로젝트 이름은 업데이트 엔진과 같은 common.sh acs_compose를 쓴다.

set -uo pipefail

# /usr/local/bin/acs 링크로 불러도 키트의 acs 폴더를 찾는다.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"
load_acs_env

# 로그를 처음에 보여 줄 줄 수입니다.
LOG_TAIL_LINES=200
OBSERVER_SERVICE_NAME="acs-update-observer"
# 이름으로 고를 수 있는 compose 서비스입니다(ACS 서비스 + 인프라).
CONTROL_SERVICES=("${ACS_SERVICES[@]}" api-gateway zenoh-router keycloak mongo postgres)

print_usage() {
  sed -n '2,14p' "$SCRIPT_DIR/acs.sh" | sed 's/^# \{0,1\}//'
}

COMMAND_NAME="${1:-status}"
[ $# -gt 0 ] && shift
FORCE_MODE=0
SERVICE_NAMES=()
for argument in "$@"; do
  case "$argument" in
    --force) FORCE_MODE=1 ;;
    -h|--help) print_usage; exit 0 ;;
    *) SERVICE_NAMES+=("$argument") ;;
  esac
done

# 서비스 이름을 확인한다. 틀리면 compose 오류 대신 고를 수 있는 이름을 보여 준다.
check_service_names() {
  local service_name
  for service_name in "${SERVICE_NAMES[@]}"; do
    if [[ " ${CONTROL_SERVICES[*]} " != *" $service_name "* ]]; then
      echo "알 수 없는 서비스입니다: $service_name (고를 수 있는 서비스: ${CONTROL_SERVICES[*]})" >&2
      exit 2
    fi
  done
}

# 업데이트 엔진(update.sh)이 잠금을 잡고 있으면 업데이트 중이다. 그동안 서비스를 바꾸면 엔진의 헬스체크·되돌리기와 겹친다.
refuse_during_update() {
  local lock_path="$DEPLOY_DIR/.update.lock"
  [ "$FORCE_MODE" -eq 1 ] && return 0
  [ -e "$lock_path" ] || return 0
  # 읽기로 열어도 잠글 수 있어 root가 만든 잠금 파일도 확인된다. 확인만 하고 바로 놓는다.
  exec 9<"$lock_path" || return 0
  if ! flock -n 9; then
    exec 9<&-
    echo "⏸️  지금 업데이트가 진행 중입니다($(release_tool json-get "$STATUS_FILE" stage 2>/dev/null)). 끝난 뒤 다시 하거나 --force를 붙이세요." >&2
    exit 75
  fi
  flock -u 9
  exec 9<&-
}

show_version() {
  # 브랜치(온라인 채널)도 함께 보여 줍니다. 예전 ZIP으로 설치한 서비스는 브랜치를 모릅니다.
  python3 -I -c '
import json, sys
try:
    installed = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    print("설치 버전: 없음")
    sys.exit(0)
installed_branch = installed.get("branch")
print("설치 버전: %s%s" % (installed.get("version") or "없음", " (%s)" % installed_branch if installed_branch else ""))
for service_name, service_entry in sorted((installed.get("services") or {}).items()):
    service_entry = service_entry or {}
    service_branch = service_entry.get("branch")
    print("  %-10s %s%s" % (service_name, service_entry.get("version") or "-", "  (%s)" % service_branch if service_branch else ""))
' "$INSTALLED_FILE"
}

case "$COMMAND_NAME" in
  status)
    show_version
    echo "업데이트 상태: $(release_tool json-get "$STATUS_FILE" state 2>/dev/null || echo '기록 없음') $(release_tool json-get "$STATUS_FILE" message 2>/dev/null)"
    if command -v systemctl >/dev/null 2>&1; then
      echo "observer: $(systemctl is-active "$OBSERVER_SERVICE_NAME" 2>/dev/null || echo '확인 불가')"
    fi
    echo ""
    acs_compose ps
    ;;
  start)
    check_service_names
    refuse_during_update
    acs_compose up -d "${SERVICE_NAMES[@]}"
    ;;
  stop)
    check_service_names
    refuse_during_update
    acs_compose stop "${SERVICE_NAMES[@]}"
    ;;
  restart)
    check_service_names
    refuse_during_update
    acs_compose restart "${SERVICE_NAMES[@]}"
    ;;
  logs)
    check_service_names
    acs_compose logs -f --tail "$LOG_TAIL_LINES" "${SERVICE_NAMES[@]}"
    ;;
  version)
    show_version
    ;;
  observer)
    case "${SERVICE_NAMES[0]:-status}" in
      status) systemctl status "$OBSERVER_SERVICE_NAME" --no-pager ;;
      restart) sudo systemctl restart "$OBSERVER_SERVICE_NAME" && echo "✅ $OBSERVER_SERVICE_NAME 재시작" ;;
      logs) journalctl -u "$OBSERVER_SERVICE_NAME" -f -n "$LOG_TAIL_LINES" ;;
      *) echo "observer 다음에는 status·restart·logs 중 하나를 쓰세요." >&2; exit 2 ;;
    esac
    ;;
  help) print_usage ;;
  *)
    echo "알 수 없는 명령입니다: $COMMAND_NAME" >&2
    print_usage >&2
    exit 2
    ;;
esac
