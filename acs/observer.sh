#!/bin/bash
# observer.sh — 업데이트 디렉터리(ACS_ROOT/deploy/observe)를 감시하다가 릴리즈 ZIP이 오면 update.sh로 적용한다.
# systemd 서비스(acs-update-observer)로 상시 실행된다. deploy.sh가 등록한다.
# Debugger 버전 탭 업로드 → Common이 observe/<이름>.zip으로 놓음 → 여기서 감지 → 적용 → status.json·installed.json 기록.
#
# - inotifywait가 있으면 ZIP이 놓이는 즉시(close_write·moved_to) 깨어나고, 없으면 CHECK_INTERVAL_SEC마다 확인한다.
# - 매 주기 observer.json heartbeat를 써서 버전 탭이 observer 동작 여부를 보여 준다.
# - 적용 결과: 0이면 ZIP 삭제, 75(실행 중 Task 대기)면 ZIP을 두고 다음 주기에 다시, 그 밖은 deploy/failed/로 옮겨 반복 적용을 막는다.
# 온라인(인터넷 되는 현장만):
# - ONLINE_CHECK_INTERVAL_SEC마다 latest.json·서비스별 version.json을 받아 online.json(버전 탭 최신 버전 표시)을 쓴다.
# - 버전 탭 요청(deploy/requests/*.json: check 다시 확인, update 전체·서비스 업데이트)을 받아 ZIP을 observe/에 넣는다.
# - 자동 업데이트(버전 탭 auto-update.json, 없으면 ACS_ONLINE_AUTO_UPDATE)가 켜져 있으면 새 버전을 스스로 받는다.
# 받은 ZIP은 업로드 ZIP과 같이 실행 중 Task 대기·강제 적용·실패 처리를 거친다. 로컬 ZIP이 있으면 그것을 먼저 처리한다.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"
load_acs_env

# 적용에 쓸 업데이트 엔진. 테스트만 ACS_UPDATE_SCRIPT로 바꿔 엔진이 기록 없이 죽는 경우를 흉내 낸다.
UPDATE_SCRIPT="${ACS_UPDATE_SCRIPT:-$SCRIPT_DIR/update.sh}"
FAILED_DIR="$DEPLOY_DIR/failed"
# 남겨 둘 실패 ZIP 개수
FAILED_KEEP=3
# 한 번만 확인하고 끝낸다(테스트용).
RUN_ONCE=0
[ "${1:-}" = "--once" ] && RUN_ONCE=1

mkdir -p "$OBSERVE_DIR" "$FAILED_DIR" "$REQUESTS_DIR"
# 실행 중 Task 때문에 기다리는 ZIP 경로
WAITING_PACKAGE=""
# 마지막 온라인 조회 시각(SECONDS). -1이면 다음 주기에 바로 조회한다(시작·업데이트 직후).
LAST_ONLINE_CHECK=-1
# 이보다 오래된(밀리초) 온라인 업데이트 요청은 버린다. 예전 키트가 처리하지 못해 남은 요청이 키트를 바꾼 뒤 뜻밖에 적용되지 않게 한다.
ONLINE_REQUEST_STALE_MS=600000

# 가장 최근 ZIP. Common이 받는 중인 파일(.<이름>.part)은 .zip이 아니라 고르지 않는다.
latest_package() {
  find "$OBSERVE_DIR" -maxdepth 1 -type f -name '*.zip' ! -name '.*' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n1 | cut -d' ' -f2-
}

# 지금 적용할 자동 업데이트 설정을 "<1|0> <출처>"로 출력한다. 버전 탭에서 바꾼 값(ui)이 설치 설정 파일(site-config)보다 우선한다.
effective_auto_update() {
  local enabled_value
  if [ -f "$AUTO_UPDATE_FILE" ]; then
    enabled_value="$(release_tool json-get "$AUTO_UPDATE_FILE" enabled 2>/dev/null)"
    [ "$enabled_value" = "True" ] && echo "1 ui" || echo "0 ui"
    return
  fi
  [ "$ACS_ONLINE_AUTO_UPDATE" = "1" ] && echo "1 site-config" || echo "0 site-config"
}

# 온라인 최신 버전을 받아 online.json을 쓴다. 인터넷이 없으면 처음 두 파일에서 포기해 observer 주기를 오래 막지 않는다.
refresh_online_status() {
  [ "$ACS_ONLINE_CHECK" = "1" ] && [ -n "$ACS_RELEASE_BASE_URL" ] || return 1
  local check_dir="$DEPLOY_DIR/.online-check" service_name received_count=0 failed_count=0 auto_update_setting
  rm -rf "$check_dir"
  mkdir -p "$check_dir/services"
  # 통합 버전이 아직 없는 채널(서비스만 배포)도 있으므로 latest.json이 없어도 서비스별 버전은 본다.
  if download_file "$ACS_RELEASE_BASE_URL/latest.json" "$check_dir/latest.json" 8 2>>"$check_dir/error" && [ -s "$check_dir/latest.json" ]; then
    received_count=1
  else
    failed_count=1
  fi
  for service_name in "${ACS_SERVICES[@]}"; do
    if download_file "$ACS_RELEASE_BASE_URL/$service_name/version.json" "$check_dir/services/$service_name.json" 8 2>>"$check_dir/error" \
      && [ -s "$check_dir/services/$service_name.json" ]; then
      received_count=$((received_count + 1))
    else
      rm -f "$check_dir/services/$service_name.json"
      failed_count=$((failed_count + 1))
      [ "$received_count" -eq 0 ] && [ "$failed_count" -ge 2 ] && break
    fi
  done
  read -r auto_update_setting auto_update_source <<< "$(effective_auto_update)"
  release_tool online-summary "$check_dir" "$INSTALLED_FILE" "$ONLINE_FILE" "$ACS_RELEASE_CHANNEL" "$ACS_RELEASE_BASE_URL" \
    "$auto_update_setting" "$auto_update_source" >/dev/null 2>&1 || true
  rm -rf "$check_dir"
  LAST_ONLINE_CHECK=$SECONDS
  # 확인 결과를 한 줄 남긴다(observer 로그에서 주기 확인이 도는지 보이게).
  log "🌐 온라인 버전 확인($ACS_RELEASE_CHANNEL): $(release_tool online-describe "$ONLINE_FILE" 2>/dev/null || echo "결과를 쓰지 못했습니다")"
}

# online.json의 대상(total 또는 서비스 이름)을 받아 sha256을 확인하고 observe/에 넣는다. 그 뒤 처리는 업로드 ZIP과 같다.
fetch_online_target() {  # <target> <source> <force(1|0)>
  local target_name="$1" run_source="$2" force_value="$3"
  local relative_path expected_sha target_version package_name actual_sha run_id
  local partial_path="$OBSERVE_DIR/.online-update.part"
  RUN_FILE=""
  if [ "$target_name" = "total" ]; then
    relative_path="$(release_tool json-get "$ONLINE_FILE" total.path)"
    expected_sha="$(release_tool json-get "$ONLINE_FILE" total.sha256)"
    target_version="$(release_tool json-get "$ONLINE_FILE" total.version)"
    package_name="$(basename "$relative_path")"
  else
    relative_path="$(release_tool json-get "$ONLINE_FILE" "services.$target_name.path")"
    expected_sha="$(release_tool json-get "$ONLINE_FILE" "services.$target_name.sha256")"
    target_version="$(release_tool json-get "$ONLINE_FILE" "services.$target_name.version")"
    package_name="acs-$target_name-$target_version.zip"
  fi
  run_id="$(new_run_id)"
  release_tool run-start "$RUNS_DIR" "$run_id" "$run_source" "$package_name" >/dev/null 2>&1 || true
  RUN_FILE="$RUNS_DIR/$run_id.json"
  if [ "$(release_tool json-get "$ONLINE_FILE" reachable)" != "True" ] || [ -z "$relative_path" ] || [ -z "$target_version" ]; then
    log "❌ 온라인 업데이트 대상을 찾지 못했습니다: $target_name"
    write_status failed download "온라인 최신 버전을 확인하지 못했습니다($target_name). 인터넷 연결과 채널을 확인하세요" "$package_name" "$target_version"
    RUN_FILE=""
    return 1
  fi
  case "$relative_path" in
    /*|*".."*) write_status failed download "온라인 업데이트 경로가 올바르지 않습니다" "$package_name" "$target_version"; RUN_FILE=""; return 1 ;;
  esac
  # 통합 업데이트 ZIP은 sha256이 꼭 있고, 서비스 ZIP은 새로 배포한 것부터 있다(없으면 update.sh가 ZIP 안의 파일별 sha256을 검증).
  if [ "$target_name" = "total" ] || [ -n "$expected_sha" ]; then
    [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] \
      || { write_status failed download "온라인 업데이트 sha256이 올바르지 않습니다" "$package_name" "$target_version"; RUN_FILE=""; return 1; }
  fi
  rm -f "$partial_path" "$OBSERVE_DIR/..online-update.part.part"
  log "🌐 온라인 업데이트($run_source): $target_name $target_version 다운로드"
  write_status downloading download "온라인 업데이트를 다운로드하는 중($target_name $target_version)" "$package_name" "$target_version"
  if ! download_file "$ACS_RELEASE_BASE_URL/$relative_path" "$partial_path" 1800 1; then
    log "⚠️  온라인 업데이트 다운로드 실패: $relative_path"
    write_status failed download "온라인 업데이트를 받지 못했습니다($relative_path)" "$package_name" "$target_version"
    rm -f "$partial_path"
    RUN_FILE=""
    return 1
  fi
  if [ -n "$expected_sha" ]; then
    actual_sha="$(sha256sum "$partial_path" | cut -d' ' -f1)"
    if [ "$actual_sha" != "$expected_sha" ]; then
      log "❌ 온라인 업데이트 sha256 불일치: $package_name"
      write_status failed download "온라인 업데이트 sha256이 맞지 않습니다" "$package_name" "$target_version"
      rm -f "$partial_path"
      RUN_FILE=""
      return 1
    fi
  fi
  # 출처·실행 ID를 ZIP보다 먼저 써야 observer가 ZIP을 보자마자 같은 실행 기록에 이어 쓴다.
  printf '{"source": "%s", "run_id": "%s"}\n' "$run_source" "$run_id" > "$OBSERVE_DIR/$package_name.meta.json"
  [ "$force_value" = "1" ] && : > "$OBSERVE_DIR/$package_name.force"
  mv -f "$partial_path" "$OBSERVE_DIR/$package_name"
  log "📥 온라인 업데이트 다운로드 완료: $package_name"
  RUN_FILE=""
}

# 버전 탭 요청을 오래된 것부터 처리한다. 다시 확인은 한 번만 조회하고, 업데이트는 대기 중 ZIP이 없을 때 하나만 받는다.
handle_online_requests() {
  local request_path request_kind request_target request_force request_requested_at checked=0
  while IFS= read -r request_path; do
    [ -n "$request_path" ] || continue
    request_kind="$(release_tool json-get "$request_path" kind 2>/dev/null)"
    case "$request_kind" in
      check)
        rm -f "$request_path"
        [ "$checked" -eq 1 ] || { refresh_online_status; checked=1; }
        ;;
      update)
        request_requested_at="$(release_tool json-get "$request_path" requested_at 2>/dev/null)"
        if [[ "$request_requested_at" =~ ^[0-9]+$ ]] && [ $(( $(date +%s%3N) - request_requested_at )) -gt "$ONLINE_REQUEST_STALE_MS" ]; then
          log "⚠️  오래된 온라인 업데이트 요청을 버립니다: $(basename "$request_path")"
          rm -f "$request_path"
          continue
        fi
        [ -z "$(latest_package)" ] || continue
        request_target="$(release_tool json-get "$request_path" target 2>/dev/null)"
        request_force="$(release_tool json-get "$request_path" force 2>/dev/null)"
        rm -f "$request_path"
        # 요청 직전 최신 버전으로 받도록 다시 조회한다.
        [ "$checked" -eq 1 ] || { refresh_online_status; checked=1; }
        [[ "$request_target" =~ ^[a-z][a-z0-9_-]*$ ]] || { log "⚠️  알 수 없는 온라인 업데이트 대상: $request_target"; continue; }
        fetch_online_target "$request_target" ui-online "$([ "$request_force" = "True" ] && echo 1 || echo 0)"
        ;;
      *)
        log "⚠️  알 수 없는 버전 탭 요청을 지웁니다: $(basename "$request_path")"
        rm -f "$request_path"
        ;;
    esac
  done < <(find "$REQUESTS_DIR" -maxdepth 1 -type f -name '*.json' ! -name '.*' 2>/dev/null | sort)
}

# 자동 업데이트가 켜져 있고 대기 중 ZIP이 없으면, 새 통합 버전(없으면 새 서비스 버전 하나)을 받는다.
auto_update_online() {
  RUN_FILE=""
  [ "$(effective_auto_update | cut -d' ' -f1)" = "1" ] || return 1
  [ -z "$(latest_package)" ] || return 1
  [ -f "$ONLINE_FILE" ] || return 1
  local target_name
  target_name="$(release_tool online-next "$ONLINE_FILE" "$INSTALLED_FILE" 2>/dev/null)"
  [ -n "$target_name" ] || return 1
  fetch_online_target "$target_name" online-auto 0
}

apply_pending_package() {
  local package_path force_marker update_arguments update_result
  package_path="$(latest_package)"
  [ -n "$package_path" ] || return 0
  force_marker="$package_path.force"
  update_arguments=()
  [ -f "$force_marker" ] && update_arguments+=(--force)
  # 출처·실행 ID는 ZIP 옆 <ZIP>.meta.json에 둔다. Common(UI 업로드·되돌리기)과 observer(온라인 자동)가 쓰고,
  # 없으면 누군가 observe/에 직접 넣은 ZIP(offline-file)이다. 실행 ID가 없으면 여기서 정해 기다렸다 다시 시도해도 같은 기록을 쓴다.
  local meta_path="$package_path.meta.json" run_source run_id
  run_source="$(release_tool json-get "$meta_path" source 2>/dev/null)"
  run_id="$(release_tool json-get "$meta_path" run_id 2>/dev/null)"
  run_source="${run_source:-offline-file}"
  if [ -z "$run_id" ]; then
    run_id="$(new_run_id)"
    printf '{"source": "%s", "run_id": "%s"}\n' "$run_source" "$run_id" > "$meta_path"
  fi
  update_arguments+=(--source="$run_source" --run-id="$run_id")
  release_tool run-start "$RUNS_DIR" "$run_id" "$run_source" "$(basename "$package_path")" >/dev/null 2>&1 || true
  RUN_FILE="$RUNS_DIR/$run_id.json"
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
  # update.sh가 로그(update.log)를 열기 전에 죽으면 이유가 stderr에만 남는다. 받아 두었다가 실패 이유로 기록한다.
  local error_file="$DEPLOY_DIR/.update-stderr.log"
  CURRENT_PACKAGE="$(basename "$package_path")" bash "$UPDATE_SCRIPT" "${update_arguments[@]}" "$working_copy" 2>"$error_file"
  update_result=$?
  [ -s "$error_file" ] && cat "$error_file" >&2
  rm -f "$working_copy"

  case "$update_result" in
    0)
      rm -f "$package_path" "$force_marker" "$meta_path"
      WAITING_PACKAGE=""
      # 설치 버전이 바뀌었으니 다음 주기에 온라인 최신 버전과 다시 비교한다.
      LAST_ONLINE_CHECK=-1
      ;;
    75)
      [ "$package_path" = "$WAITING_PACKAGE" ] || log "⏸️  실행 중인 Task가 끝나면 다시 시도합니다."
      WAITING_PACKAGE="$package_path"
      ;;
    *)
      WAITING_PACKAGE=""
      record_unexplained_failure "$update_result" "$error_file" "$(basename "$package_path")"
      log "❌ 적용 실패(종료 코드 $update_result) → $FAILED_DIR 로 옮깁니다."
      mv -f "$package_path" "$FAILED_DIR/" 2>/dev/null || rm -f "$package_path"
      rm -f "$force_marker" "$meta_path"
      find "$FAILED_DIR" -maxdepth 1 -type f -name '*.zip' -printf '%T@ %p\n' | sort -n | head -n "-$FAILED_KEEP" | cut -d' ' -f2- | xargs -r rm -f
      ;;
  esac
  rm -f "$error_file"
  RUN_FILE=""
}

# update.sh가 단계 기록 없이 끝났으면(옵션·설정 오류, 예기치 못한 종료 등) 종료 코드와 stderr 끝부분을
# 실행 기록·상태·update.log에 남긴다. 그래야 failed/로 옮긴 이유를 Debugger 업데이트 이력에서 볼 수 있다.
record_unexplained_failure() {  # <exit_code> <stderr_file> <package_name>
  local run_result failure_detail failure_message
  run_result="$(release_tool json-get "$RUN_FILE" result 2>/dev/null)"
  [ "$run_result" = "failed" ] && return 0
  failure_detail="$(tail -n 3 "$2" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
  failure_message="업데이트 엔진이 이유를 남기지 않고 종료했습니다(종료 코드 $1). ZIP을 failed/로 옮깁니다.${failure_detail:+ $failure_detail}"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ $3: $failure_message" >> "$UPDATE_LOG"
  release_tool run-note "$RUN_FILE" error apply "$failure_message" >/dev/null 2>&1 || true
  write_status failed apply "$failure_message" "$3" ""
}

wait_for_next_check() {
  if command -v inotifywait >/dev/null 2>&1; then
    # 버전 탭 요청(requests/)도 바로 처리하도록 함께 본다.
    inotifywait -q -t "$CHECK_INTERVAL_SEC" -e close_write,moved_to "$OBSERVE_DIR" "$REQUESTS_DIR" >/dev/null 2>&1 || true
  else
    sleep "$CHECK_INTERVAL_SEC"
  fi
}

# 이미 설치한 현장도 키트만 받고 observer를 다시 시작하면 acs 명령이 생기게 한다(observer는 root로 돈다).
[ -w "$(dirname "$ACS_COMMAND_LINK")" ] && link_acs_command
log "👀 ACS observer 시작: $OBSERVE_DIR (주기 ${CHECK_INTERVAL_SEC}초, inotify $(command -v inotifywait >/dev/null 2>&1 && echo 사용 || echo 없음))"
while :; do
  # 설정 파일만 바꾸고 서비스를 재시작하지 않아도 다음 주기에 on/off와 URL이 반영된다.
  load_acs_env
  write_heartbeat
  handle_online_requests
  apply_pending_package
  if [ "$ACS_ONLINE_CHECK" = "1" ] && { [ "$LAST_ONLINE_CHECK" -lt 0 ] || [ $((SECONDS - LAST_ONLINE_CHECK)) -ge "$ONLINE_CHECK_INTERVAL_SEC" ]; }; then
    refresh_online_status
  fi
  if auto_update_online; then
    apply_pending_package
  fi
  [ "$RUN_ONCE" -eq 1 ] && break
  wait_for_next_check
done
