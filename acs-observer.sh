#!/bin/bash
# acs-observer.sh — 업데이트 디렉터리(ACS_ROOT/deploy/observe)를 감시하다가 릴리즈 ZIP이 오면 acs-update.sh로 적용한다.
# systemd 서비스(acs-update-observer)로 상시 실행된다. deploy.sh가 등록한다.
# Debugger 버전 탭 업로드 → Common이 observe/<이름>.zip으로 놓음 → 여기서 감지 → 적용 → status.json·installed.json 기록.
#
# - inotifywait가 있으면 ZIP이 놓이는 즉시(close_write·moved_to) 깨어나고, 없으면 CHECK_INTERVAL_SEC마다 확인한다.
# - 매 주기 observer.json heartbeat를 써서 버전 탭이 observer 동작 여부를 보여 준다.
# - 적용 결과: 0이면 ZIP 삭제, 75(실행 중 Task 대기)면 ZIP을 두고 다음 주기에 다시, 그 밖은 deploy/failed/로 옮겨 반복 적용을 막는다.
# Muscat muscat-version-observer.sh의 오프라인 drop 디렉터리 감시와 같은 구조다(온라인 매니페스트 확인은 없다).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
load_acs_env

UPDATE_SCRIPT="$SCRIPT_DIR/acs-update.sh"
FAILED_DIR="$DEPLOY_DIR/failed"
# 남겨 둘 실패 ZIP 개수
FAILED_KEEP=3
# 한 번만 확인하고 끝낸다(테스트용).
RUN_ONCE=0
[ "${1:-}" = "--once" ] && RUN_ONCE=1

mkdir -p "$OBSERVE_DIR" "$FAILED_DIR"
# 실행 중 Task 때문에 기다리는 ZIP 경로
WAITING_PACKAGE=""

# 가장 최근 ZIP. Common이 받는 중인 파일(.<이름>.part)은 .zip이 아니라 고르지 않는다.
latest_package() {
  find "$OBSERVE_DIR" -maxdepth 1 -type f -name '*.zip' ! -name '.*' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n1 | cut -d' ' -f2-
}

apply_pending_package() {
  local package_path force_marker update_arguments update_result
  package_path="$(latest_package)"
  [ -n "$package_path" ] || return 0
  force_marker="$package_path.force"
  update_arguments=()
  [ -f "$force_marker" ] && update_arguments+=(--force)
  # 실행 중 Task 때문에 기다리는 같은 ZIP이면 다시 알리지 않는다(상태가 주기마다 바뀌어 깜빡이지 않게).
  if [ "$package_path" != "$WAITING_PACKAGE" ] || [ -f "$force_marker" ]; then
    log "📦 업데이트 ZIP 감지: $package_path ${update_arguments[*]:-}"
    write_status queued detected "업데이트 ZIP을 감지했습니다" "$(basename "$package_path")" ""
  fi

  # 큰 ZIP을 복사하기 전에 실행 중 Task부터 본다. 기다리는 동안 매 주기 복사·압축 해제를 하지 않는다.
  if [ ! -f "$force_marker" ]; then
    local active_count
    active_count="$(active_task_count)"
    if [ "$active_count" != "unknown" ] && [ "$active_count" -gt 0 ]; then
      [ "$package_path" = "$WAITING_PACKAGE" ] || log "⏸️  실행 중인 Task ${active_count}개가 끝나면 적용합니다."
      write_status waiting wait_tasks "$(waiting_message "$active_count")" "$(basename "$package_path")" ""
      WAITING_PACKAGE="$package_path"
      return 0
    fi
  fi

  # 적용하는 동안 화면에서 취소·새 업로드를 해도 엔진이 읽는 파일은 바뀌지 않게 복사본으로 적용한다.
  local working_copy="$DEPLOY_DIR/.applying.zip"
  cp "$package_path" "$working_copy" || return 0
  CURRENT_PACKAGE="$(basename "$package_path")" bash "$UPDATE_SCRIPT" "${update_arguments[@]}" "$working_copy"
  update_result=$?
  rm -f "$working_copy"

  case "$update_result" in
    0)
      rm -f "$package_path" "$force_marker"
      WAITING_PACKAGE=""
      ;;
    75)
      [ "$package_path" = "$WAITING_PACKAGE" ] || log "⏸️  실행 중인 Task가 끝나면 다시 시도합니다."
      WAITING_PACKAGE="$package_path"
      ;;
    *)
      WAITING_PACKAGE=""
      log "❌ 적용 실패(종료 코드 $update_result) → $FAILED_DIR 로 옮깁니다."
      mv -f "$package_path" "$FAILED_DIR/" 2>/dev/null || rm -f "$package_path"
      rm -f "$force_marker"
      find "$FAILED_DIR" -maxdepth 1 -type f -name '*.zip' -printf '%T@ %p\n' | sort -n | head -n "-$FAILED_KEEP" | cut -d' ' -f2- | xargs -r rm -f
      ;;
  esac
}

wait_for_next_check() {
  if command -v inotifywait >/dev/null 2>&1; then
    inotifywait -q -t "$CHECK_INTERVAL_SEC" -e close_write,moved_to "$OBSERVE_DIR" >/dev/null 2>&1 || true
  else
    sleep "$CHECK_INTERVAL_SEC"
  fi
}

log "👀 ACS observer 시작: $OBSERVE_DIR (주기 ${CHECK_INTERVAL_SEC}초, inotify $(command -v inotifywait >/dev/null 2>&1 && echo 사용 || echo 없음))"
while :; do
  write_heartbeat
  apply_pending_package
  [ "$RUN_ONCE" -eq 1 ] && break
  wait_for_next_check
done
