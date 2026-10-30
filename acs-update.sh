#!/bin/bash
# acs-update.sh — ACS 릴리즈 ZIP(rb_acs `make release`)을 설치 디렉터리에 적용하는 업데이트 엔진.
# 사용법: acs-update.sh [--install] [--force] <acs-<버전>.zip>
#   --install  최초 설치(deploy.sh가 부름). 실행 중 Task 확인·DB 백업을 건너뛴다.
#   --force    실행 중 Task가 있어도 적용한다(버전 탭 "강제 적용", observe/<이름>.zip.force).
# 종료 코드: 0 적용 완료, 75 실행 중 Task 때문에 대기(ZIP을 두고 나중에 다시), 1 실패(바꾼 것은 되돌림), 2 사용법 오류.
#
# 순서(Muscat muscat-update.sh의 검증 → 스왑 → 재시작 → 롤백 흐름을 따른다):
#   wait_tasks Gateway로 Task 실행 목록을 보고 끝나지 않은 실행이 있으면 대기(75). 큰 ZIP을 풀기 전에 본다
#   validate   ZIP 풀기, 매니페스트 종류·형식·arch, 모든 파일 sha256, site.env와 서비스 bin 빠짐 확인
#   images     ZIP에 이미지 tar가 있으면 docker load, compose가 쓰는 이미지가 모두 있는지 확인
#   backup     MongoDB(mongodump)·PostgreSQL(pg_dump) 백업. 실패하면 아무것도 바꾸지 않고 멈춘다
#   runtime    compose·Gateway·Zenoh 설정 교체(이전 파일은 .rollback/에). api-gateway/servers의 현장 파일은 덮어쓰지 않는다
#   swap       서비스 bin을 같은 디렉터리 안에서 rename으로 교체(컨테이너는 디렉터리를 마운트해 새 파일을 본다)
#   restart    compose up -d 후 바뀐 서비스(설정이 바뀌었으면 Gateway·Zenoh router도) 재시작
#   health     모든 ACS 서비스가 healthy가 될 때까지 대기. 실패하면 설정·bin을 되돌리고 다시 띄운다
# DB는 자동으로 되돌리지 않는다(마이그레이션은 앞으로만 간다). 필요하면 backups/<시각>/의 백업으로 복구한다.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
load_acs_env

INSTALL_MODE=0
FORCE_MODE=0
PACKAGE_PATH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --install) INSTALL_MODE=1 ;;
    --force) FORCE_MODE=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    -*) echo "알 수 없는 옵션: $1" >&2; exit 2 ;;
    *) PACKAGE_PATH="$1" ;;
  esac
  shift
done
[ -n "$PACKAGE_PATH" ] && [ -f "$PACKAGE_PATH" ] || { echo "사용법: $(basename "$0") [--install] [--force] <acs-<버전>.zip>" >&2; exit 2; }
PACKAGE_PATH="$(cd "$(dirname "$PACKAGE_PATH")" && pwd)/$(basename "$PACKAGE_PATH")"

mkdir -p "$DEPLOY_DIR" "$OBSERVE_DIR" "$ACS_ROOT/services" "$ACS_ROOT/backups"
# 로그가 끝없이 커지지 않게 2MB를 넘으면 마지막 2000줄만 남긴다.
if [ -f "$UPDATE_LOG" ] && [ "$(stat -c %s "$UPDATE_LOG" 2>/dev/null || echo 0)" -gt 2097152 ]; then
  tail -n 2000 "$UPDATE_LOG" > "$UPDATE_LOG.tmp" && mv "$UPDATE_LOG.tmp" "$UPDATE_LOG"
fi
exec > >(tee -a "$UPDATE_LOG") 2>&1

# 업데이트는 한 번에 하나만 한다(observer와 수동 실행이 겹치지 않게).
exec 9>"$DEPLOY_DIR/.update.lock"
if ! flock -n 9; then
  log "다른 업데이트가 진행 중입니다. 나중에 다시 시도합니다."
  exit 75
fi

# observer는 복사본으로 적용하므로 원래 ZIP 이름을 CURRENT_PACKAGE로 넘긴다.
CURRENT_PACKAGE="${CURRENT_PACKAGE:-$(basename "$PACKAGE_PATH")}"
CURRENT_VERSION=""
STAGING_DIR="$ACS_ROOT/.staging"
ROLLBACK_DIR="$ACS_ROOT/.rollback"
BIN_ARCH="$(host_arch)"
UPDATED_SERVICES=()
CURRENT_STAGE="wait_tasks"

cleanup_staging() {
  rm -rf "$STAGING_DIR" "$STAGING_DIR.err"
}

# 아직 아무것도 바꾸지 않은 단계의 실패. 이력만 남기고 끝낸다.
fail_without_changes() {  # <message>
  log "❌ $1"
  write_status failed "$CURRENT_STAGE" "$1"
  [ -f "$STAGING_DIR/version.json" ] && release_tool record "$INSTALLED_FILE" "$STAGING_DIR" "" failed "$1" || true
  cleanup_staging
  exit 1
}

# 설정·bin을 바꾼 뒤의 실패. 이전 설정·bin으로 되돌리고 다시 띄운다.
fail_with_rollback() {  # <message>
  local failure_message=$1
  log "❌ $failure_message → 이전 버전으로 되돌립니다."
  CURRENT_STAGE="rollback"
  write_status running rollback "$failure_message. 이전 버전으로 되돌리는 중"
  rollback_changes
  local rollback_result="이전 버전으로 되돌렸습니다"
  if ! wait_services_healthy "$HEALTH_TIMEOUT_SEC" "${ACS_SERVICES[@]}" >/dev/null; then
    rollback_result="되돌린 뒤에도 일부 서비스가 healthy가 아닙니다. acs-ctl.sh status로 확인하세요"
  fi
  write_status failed rollback "$failure_message. $rollback_result"
  release_tool record "$INSTALLED_FILE" "$STAGING_DIR" "" failed "$failure_message. $rollback_result" || true
  cleanup_staging
  exit 1
}

rollback_changes() {
  local relative_path service_name bin_name
  if [ -d "$ROLLBACK_DIR/runtime" ]; then
    (cd "$ROLLBACK_DIR/runtime" && find . -type f -printf '%P\n') | while IFS= read -r relative_path; do
      install -D -m 644 "$ROLLBACK_DIR/runtime/$relative_path" "$ACS_ROOT/$relative_path"
    done
  fi
  if [ -f "$ROLLBACK_DIR/runtime-created.txt" ]; then
    while IFS= read -r relative_path; do
      [ -n "$relative_path" ] && rm -f "$ACS_ROOT/$relative_path"
    done < "$ROLLBACK_DIR/runtime-created.txt"
  fi
  for service_name in "${UPDATED_SERVICES[@]}"; do
    bin_name="$service_name.$BIN_ARCH.bin"
    if [ -f "$ROLLBACK_DIR/services/$service_name/$bin_name" ]; then
      cp -p "$ROLLBACK_DIR/services/$service_name/$bin_name" "$ACS_ROOT/services/$service_name/$bin_name.new"
      mv -f "$ACS_ROOT/services/$service_name/$bin_name.new" "$ACS_ROOT/services/$service_name/$bin_name"
    fi
  done
  acs_compose up -d --no-build --pull never --remove-orphans || true
  [ ${#UPDATED_SERVICES[@]} -gt 0 ] && acs_compose restart "${UPDATED_SERVICES[@]}" || true
  acs_compose restart api-gateway zenoh-router >/dev/null 2>&1 || true
}

log "════ 업데이트 시작: $CURRENT_PACKAGE (설치=$INSTALL_MODE, 강제=$FORCE_MODE)"
write_heartbeat

# ── wait_tasks(큰 ZIP을 풀기 전에 먼저 본다. 기다리는 동안 매 주기 다시 풀지 않게) ──
if [ "$INSTALL_MODE" -eq 0 ] && [ "$FORCE_MODE" -eq 0 ]; then
  CURRENT_STAGE="wait_tasks"
  active_count="$(active_task_count)"
  if [ "$active_count" = "unknown" ]; then
    log "⚠️  Task 서비스가 응답하지 않습니다($ACS_GATEWAY_URL). 실행 중인 Task가 없다고 보고 진행합니다."
  elif [ "$active_count" -gt 0 ]; then
    log "실행 중인 Task ${active_count}개 → 끝나면 업데이트합니다."
    write_status waiting wait_tasks "$(waiting_message "$active_count")"
    exit 75
  fi
fi

# ── validate ─────────────────────────────────────
CURRENT_STAGE="validate"
write_status running validate "ZIP을 검증하는 중"
cleanup_staging
mkdir -p "$STAGING_DIR"
release_tool extract "$PACKAGE_PATH" "$STAGING_DIR" 2> "$STAGING_DIR.err" || fail_without_changes "$(cat "$STAGING_DIR.err")"
release_tool validate "$STAGING_DIR" "$BIN_ARCH" 2> "$STAGING_DIR.err" || fail_without_changes "$(cat "$STAGING_DIR.err")"
rm -f "$STAGING_DIR.err"
CURRENT_VERSION="$(release_tool get "$STAGING_DIR" version)"
IFS=',' read -r -a UPDATED_SERVICES <<< "$(release_tool get "$STAGING_DIR" services)"
IMAGES_ARCHIVE="$(release_tool get "$STAGING_DIR" images.archive)"
log "버전 $CURRENT_VERSION, 서비스: ${UPDATED_SERVICES[*]:-없음}, 이미지 포함: ${IMAGES_ARCHIVE:-아니오}"

[ -f "$ACS_ROOT/site.env" ] || fail_without_changes "site.env가 없습니다. deploy.sh로 설치하거나 site.env.example을 복사해 현장 값을 채우세요."
missing_services=()
for service_name in "${ACS_SERVICES[@]}"; do
  if [ ! -f "$STAGING_DIR/services/$service_name/$service_name.$BIN_ARCH.bin" ] && [ ! -f "$ACS_ROOT/services/$service_name/$service_name.$BIN_ARCH.bin" ]; then
    missing_services+=("$service_name")
  fi
done
[ ${#missing_services[@]} -eq 0 ] || fail_without_changes "설치되지 않은 서비스가 ZIP에도 없습니다: ${missing_services[*]}. 전체 서비스 릴리즈로 설치하세요."

# ── images ───────────────────────────────────────
CURRENT_STAGE="images"
if [ -n "$IMAGES_ARCHIVE" ]; then
  write_status running images "이미지를 불러오는 중(몇 분 걸릴 수 있습니다)"
  log "docker load: $IMAGES_ARCHIVE"
  docker load -i "$STAGING_DIR/$IMAGES_ARCHIVE" || fail_without_changes "이미지를 불러오지 못했습니다."
  IMAGE_TAG="$(release_tool get "$STAGING_DIR" images.tag)"
else
  IMAGE_TAG="$(release_tool installed-get "$INSTALLED_FILE" images_tag)"
  if [ -z "$IMAGE_TAG" ] && [ -f "$ACS_ROOT/.env" ]; then
    IMAGE_TAG="$(sed -n 's/^ACS_IMAGE_TAG=//p' "$ACS_ROOT/.env" | tail -n1)"
  fi
fi
[ -n "$IMAGE_TAG" ] || fail_without_changes "설치된 이미지 태그를 모릅니다. 처음 설치는 이미지가 든 릴리즈 ZIP(make release IMAGES=1)으로 하세요."
cp "$STAGING_DIR/runtime/.env" "$STAGING_DIR/runtime/.env.with-tag"
{
  echo "# Gateway·Zenoh router 이미지 태그(acs-update.sh가 설치된 이미지 기준으로 붙임)"
  echo "ACS_IMAGE_TAG=$IMAGE_TAG"
} >> "$STAGING_DIR/runtime/.env.with-tag"
staged_compose_files=(-f "$STAGING_DIR/runtime/compose.yml" -f "$STAGING_DIR/runtime/compose.offline.yml")
[ -f "$ACS_ROOT/compose.site.yml" ] && staged_compose_files+=(-f "$ACS_ROOT/compose.site.yml")
required_images="$(docker compose -p "$ACS_PROJECT" --project-directory "$ACS_ROOT" --env-file "$STAGING_DIR/runtime/.env.with-tag" --env-file "$ACS_ROOT/site.env" "${staged_compose_files[@]}" config --images 2> "$STAGING_DIR.err")" \
  || fail_without_changes "새 compose 설정을 해석하지 못했습니다: $(tail -n 3 "$STAGING_DIR.err")"
rm -f "$STAGING_DIR.err"
missing_images=()
for image_name in $required_images; do
  docker image inspect "$image_name" >/dev/null 2>&1 || missing_images+=("$image_name")
done
[ ${#missing_images[@]} -eq 0 ] || fail_without_changes "필요한 이미지가 없습니다: ${missing_images[*]}. 이미지가 든 릴리즈 ZIP(make release IMAGES=1)을 올리세요."

# ── backup ───────────────────────────────────────
CURRENT_STAGE="backup"
if [ "$INSTALL_MODE" -eq 0 ] && [ -n "$(acs_compose ps -q mongo 2>/dev/null)" ]; then
  write_status running backup "DB를 백업하는 중"
  backup_dir="$ACS_ROOT/backups/$(date '+%Y%m%d-%H%M%S')-$CURRENT_VERSION"
  mkdir -p "$backup_dir"
  acs_compose exec -T mongo mongodump --archive --gzip --quiet > "$backup_dir/mongo.archive.gz" \
    || fail_without_changes "MongoDB 백업에 실패했습니다. 아무것도 바꾸지 않았습니다."
  if [ -n "$(acs_compose ps -q postgres 2>/dev/null)" ]; then
    acs_compose exec -T postgres pg_dump -U state -d state | gzip > "$backup_dir/postgres.sql.gz" \
      || fail_without_changes "PostgreSQL 백업에 실패했습니다. 아무것도 바꾸지 않았습니다."
  fi
  log "DB 백업: $backup_dir"
  # 오래된 백업은 BACKUP_KEEP개만 남긴다.
  find "$ACS_ROOT/backups" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | head -n "-$BACKUP_KEEP" | while IFS= read -r old_backup; do
    rm -rf "${ACS_ROOT:?}/backups/$old_backup"
  done
fi

# ── runtime ──────────────────────────────────────
CURRENT_STAGE="runtime"
write_status running runtime "설정 파일을 바꾸는 중"
rm -rf "$ROLLBACK_DIR"
mkdir -p "$ROLLBACK_DIR/runtime" "$ROLLBACK_DIR/services"
: > "$ROLLBACK_DIR/runtime-created.txt"
changed_runtime_paths=()
while IFS= read -r relative_path; do
  [ "$relative_path" = ".env.with-tag" ] && continue
  source_path="$STAGING_DIR/runtime/$relative_path"
  target_relative_path="$relative_path"
  [ "$relative_path" = ".env" ] && source_path="$STAGING_DIR/runtime/.env.with-tag"
  target_path="$ACS_ROOT/$target_relative_path"
  # Gateway 외부 플랫폼 서버 블록은 현장에서 고치는 파일이라 없을 때만 놓는다.
  case "$relative_path" in
    api-gateway/servers/*) [ -f "$target_path" ] && continue ;;
  esac
  if [ -f "$target_path" ]; then
    cmp -s "$source_path" "$target_path" && continue
    install -D -m 644 "$target_path" "$ROLLBACK_DIR/runtime/$target_relative_path"
  else
    echo "$target_relative_path" >> "$ROLLBACK_DIR/runtime-created.txt"
  fi
  install -D -m 644 "$source_path" "$target_path"
  changed_runtime_paths+=("$target_relative_path")
done < <(cd "$STAGING_DIR/runtime" && find . -type f -printf '%P\n' | sort)
log "바뀐 설정 파일: ${changed_runtime_paths[*]:-없음}"

# ── swap ─────────────────────────────────────────
CURRENT_STAGE="swap"
write_status running swap "서비스 bin을 바꾸는 중: ${UPDATED_SERVICES[*]}"
for service_name in "${UPDATED_SERVICES[@]}"; do
  bin_name="$service_name.$BIN_ARCH.bin"
  service_dir="$ACS_ROOT/services/$service_name"
  mkdir -p "$service_dir"
  if [ -f "$service_dir/$bin_name" ]; then
    mkdir -p "$ROLLBACK_DIR/services/$service_name"
    cp -p "$service_dir/$bin_name" "$ROLLBACK_DIR/services/$service_name/$bin_name"
  fi
  # 같은 디렉터리에서 rename해야 실행 중인 컨테이너가 열어 둔 이전 파일이 깨지지 않는다.
  cp "$STAGING_DIR/services/$service_name/$bin_name" "$service_dir/$bin_name.new" || fail_with_rollback "$service_name bin을 복사하지 못했습니다"
  chmod 755 "$service_dir/$bin_name.new"
  mv -f "$service_dir/$bin_name.new" "$service_dir/$bin_name"
done

# ── restart ──────────────────────────────────────
CURRENT_STAGE="restart"
write_status running restart "서비스를 다시 시작하는 중"
# compose up이 새로 만든 컨테이너는 이미 새 bin·설정으로 떠 있으므로, 원래 있던 컨테이너만 재시작한다.
existing_services=" $(acs_compose ps -a --services 2>/dev/null | tr '\n' ' ') "
acs_compose up -d --no-build --pull never --remove-orphans || fail_with_rollback "compose up에 실패했습니다"
candidate_targets=("${UPDATED_SERVICES[@]}")
for relative_path in "${changed_runtime_paths[@]}"; do
  case "$relative_path" in
    api-gateway/*) [[ " ${candidate_targets[*]} " == *" api-gateway "* ]] || candidate_targets+=(api-gateway) ;;
    zenoh-router-acs/*) [[ " ${candidate_targets[*]} " == *" zenoh-router "* ]] || candidate_targets+=(zenoh-router) ;;
  esac
done
restart_targets=()
for service_name in "${candidate_targets[@]}"; do
  [[ "$existing_services" == *" $service_name "* ]] && restart_targets+=("$service_name")
done
if [ ${#restart_targets[@]} -gt 0 ]; then
  log "재시작: ${restart_targets[*]}"
  acs_compose restart "${restart_targets[@]}" || fail_with_rollback "서비스 재시작에 실패했습니다"
fi

# ── health ───────────────────────────────────────
CURRENT_STAGE="health"
write_status running health "서비스가 정상 기동하는지 확인하는 중"
if ! unhealthy_services="$(wait_services_healthy "$HEALTH_TIMEOUT_SEC" "${ACS_SERVICES[@]}")"; then
  fail_with_rollback "헬스체크 실패(${HEALTH_TIMEOUT_SEC}초): $unhealthy_services"
fi

# ── done ─────────────────────────────────────────
CURRENT_STAGE="done"
release_tool record "$INSTALLED_FILE" "$STAGING_DIR" "$IMAGE_TAG" success "" || true
write_status success done "$CURRENT_VERSION 적용 완료(서비스: ${UPDATED_SERVICES[*]:-없음})"
cleanup_staging
log "✅ $CURRENT_VERSION 적용 완료"
exit 0
