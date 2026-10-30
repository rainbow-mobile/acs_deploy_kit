#!/bin/bash
# acs-ctl.sh — 설치된 ACS 운영 명령. Muscat rb-ctl처럼 compose 인자를 외우지 않고 쓰게 한다.
# 사용법: acs-ctl.sh <명령> [서비스...]
#   status              버전·업데이트 상태·컨테이너 상태
#   start | stop        전체 시작·종료(데이터 볼륨은 유지)
#   restart [서비스...] 재시작(생략 시 전체)
#   logs [서비스] [-f]  컨테이너 로그
#   update <ZIP>        릴리즈 ZIP을 바로 적용(observer를 거치지 않음, 실행 중 Task가 있으면 대기)
#   observer-log        업데이트 로그(deploy/update.log) 마지막 100줄
#   compose <인자...>   설치 설정으로 docker compose 실행

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
load_acs_env

command_name="${1:-status}"
[ $# -gt 0 ] && shift

case "$command_name" in
  status)
    echo "설치 디렉터리: $ACS_ROOT (프로젝트 $ACS_PROJECT)"
    echo "설치 버전: $(release_tool installed-get "$INSTALLED_FILE" version)"
    [ -f "$STATUS_FILE" ] && echo "업데이트 상태: $(python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); print(s.get("state"), s.get("stage"), "-", s.get("message"))' "$STATUS_FILE" 2>/dev/null)"
    acs_compose ps --format 'table {{.Service}}\t{{.Status}}'
    ;;
  start) acs_compose up -d --no-build --pull never ;;
  stop) acs_compose down ;;
  restart) acs_compose restart "$@" ;;
  logs) acs_compose logs --tail 200 "$@" ;;
  update)
    [ $# -ge 1 ] || { echo "사용법: $(basename "$0") update <acs-<버전>.zip> [--force]" >&2; exit 2; }
    bash "$SCRIPT_DIR/acs-update.sh" "$@"
    ;;
  observer-log) tail -n 100 "$UPDATE_LOG" ;;
  compose) acs_compose "$@" ;;
  -h|--help|help) sed -n '2,11p' "$0" ;;
  *) echo "알 수 없는 명령: $command_name" >&2; sed -n '2,11p' "$0"; exit 2 ;;
esac
