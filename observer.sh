#!/bin/bash
# observer.sh — 업데이트 디렉터리(ACS_ROOT/deploy/observe)를 감시하다가 릴리즈 ZIP이 오면 update.sh로 적용한다.
# systemd 서비스(acs-update-observer)로 상시 실행된다. deploy.sh가 등록한다.
# Debugger 버전 탭 업로드 → Common이 observe/<이름>.zip으로 놓음 → 여기서 감지 → 적용 → status.json·installed.json 기록.
#
# - inotifywait가 있으면 ZIP이 놓이는 즉시(close_write·moved_to) 깨어나고, 없으면 CHECK_INTERVAL_SEC마다 확인한다.
# - 매 주기 observer.json heartbeat를 써서 버전 탭이 observer 동작 여부를 보여 준다.
# - 적용 결과: 0이면 ZIP 삭제, 75(실행 중 Task 대기)면 ZIP을 두고 다음 주기에 다시, 그 밖은 deploy/failed/로 옮겨 반복 적용을 막는다.
# 로컬 ZIP을 우선하고, ACS_ONLINE_AUTO_UPDATE=1인 현장만 S3/CloudFront의 latest.json도 확인한다.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"
load_acs_env

UPDATE_SCRIPT="$SCRIPT_DIR/update.sh"
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

# 온라인 최신 버전을 확인해 검증된 ZIP만 observe/에 넣는다. 기본 설정에서는 이 함수를 호출해도 네트워크를 쓰지 않는다.
download_online_package() {
  [ "$ACS_ONLINE_AUTO_UPDATE" = "1" ] || return 1
  [ -n "$ACS_RELEASE_BASE_URL" ] || return 1
  [ -z "$(latest_package)" ] || return 1

  local manifest_path="$DEPLOY_DIR/.online-latest.json"
  local partial_path="$OBSERVE_DIR/.online-update.part"
  local online_version installed_version relative_path expected_sha actual_sha package_name
  download_file "$ACS_RELEASE_BASE_URL/latest.json" "$manifest_path" 15 2>/dev/null || return 1
  [ "$(release_tool json-get "$manifest_path" kind)" = "acs.online-release" ] || { rm -f "$manifest_path"; return 1; }
  online_version="$(release_tool json-get "$manifest_path" version)"
  installed_version="$(release_tool installed-get "$INSTALLED_FILE" version)"
  [ "$(release_tool version-is-newer "$online_version" "$installed_version")" = "true" ] \
    || { rm -f "$manifest_path"; return 1; }
  relative_path="$(release_tool json-get "$manifest_path" update.path)"
  expected_sha="$(release_tool json-get "$manifest_path" update.sha256)"
  case "$relative_path" in
    ""|/*|*".."*) rm -f "$manifest_path"; return 1 ;;
  esac
  [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || { rm -f "$manifest_path"; return 1; }

  package_name="$(basename "$relative_path")"
  log "🌐 온라인 새 버전 감지: $installed_version → $online_version"
  write_status downloading online "온라인 업데이트를 다운로드하는 중" "$package_name" "$online_version"
  if ! download_file "$ACS_RELEASE_BASE_URL/$relative_path" "$partial_path" 1800; then
    log "⚠️  온라인 업데이트 다운로드 실패: $relative_path"
    rm -f "$manifest_path" "$partial_path"
    return 1
  fi
  actual_sha="$(sha256sum "$partial_path" | cut -d' ' -f1)"
  if [ "$actual_sha" != "$expected_sha" ]; then
    log "❌ 온라인 업데이트 sha256 불일치: $package_name"
    write_status failed online "온라인 업데이트 sha256이 맞지 않습니다" "$package_name" "$online_version"
    rm -f "$manifest_path" "$partial_path"
    return 1
  fi
  mv -f "$partial_path" "$OBSERVE_DIR/$package_name"
  rm -f "$manifest_path"
  log "📥 온라인 업데이트 다운로드 완료: $package_name"
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
  # 설정 파일만 바꾸고 서비스를 재시작하지 않아도 다음 주기에 on/off와 URL이 반영된다.
  load_acs_env
  write_heartbeat
  apply_pending_package
  if download_online_package; then
    apply_pending_package
  fi
  [ "$RUN_ONCE" -eq 1 ] && break
  wait_for_next_check
done
