#!/bin/bash
# tests/test-update.sh — 실제 컨테이너 없이 deploy.sh·update.sh·observer.sh 흐름을 검증한다.
# 가짜 docker·curl을 PATH 앞에 두고, 작은 가짜 릴리즈 ZIP으로 설치·부분 업데이트·검증 실패·Task 대기·롤백을 확인한다.
# 사용법: bash tests/test-update.sh

set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
FAKE_BIN_DIR="$TEST_ROOT/fake-bin"
mkdir -p "$FAKE_BIN_DIR"
export FAKE_LOG="$TEST_ROOT/fake-calls.log"
export FAKE_STATE_DIR="$TEST_ROOT/fake-state"
mkdir -p "$FAKE_STATE_DIR"
# compose가 쓴다고 답할 이미지 목록
export FAKE_IMAGES="debian:bookworm-slim rb-acs-api-gateway:v1 mongo:7"
FAILURES=0
TEST_COUNT=0

# ── 가짜 docker: compose ps -q는 컨테이너 ID, inspect는 healthy(FAKE_STATE_DIR/unhealthy-<서비스>가 있으면 unhealthy) ──
cat > "$FAKE_BIN_DIR/docker" <<'EOF'
#!/bin/bash
echo "docker $*" >> "$FAKE_LOG"
if [ "${1:-}" = "compose" ]; then
  case " $* " in
    *" version --short "*) echo "2.39.1"; exit 0 ;;
    *" version "*) echo "Docker Compose version v2.39.1"; exit 0 ;;
    *" config --images "*) for image_name in $FAKE_IMAGES; do echo "$image_name"; done; exit 0 ;;
    *" ps -q "*) echo "cid-${!#}"; exit 0 ;;
    # compose up 뒤에는 모든 컨테이너가 있는 것으로 답한다.
    *" ps -a --services "*|*" ps --services --status running "*) [ -f "$FAKE_STATE_DIR/containers-created" ] && printf '%s\n' common scenario task state external map mock api-gateway zenoh-router mongo postgres; exit 0 ;;
    *" up "*) touch "$FAKE_STATE_DIR/containers-created"; exit 0 ;;
    *" exec -T api-gateway nginx -t "*) [ -f "$FAKE_STATE_DIR/gateway-config-fails" ] && exit 1; exit 0 ;;
    *" exec -T api-gateway nginx -s reload "*)
      [ -f "$FAKE_STATE_DIR/gateway-reload-fails" ] && exit 1
      touch "$FAKE_STATE_DIR/gateway-check-pending"; exit 0 ;;
    *" mongodump "*)
      [ -f "$FAKE_STATE_DIR/mongo-backup-fails" ] && exit 1
      if [ -f "$FAKE_STATE_DIR/mongo-auth-required" ]; then
        case " $* " in
          *" mongo sh -c "*)
            MONGO_INITDB_ROOT_USERNAME=backup_test_admin MONGO_INITDB_ROOT_PASSWORD='Backup@Test!#' bash -c "${!#}"
            exit $? ;;
          *) exit 1 ;;
        esac
      fi
      echo "mongo-backup"; exit 0 ;;
    *" pg_dump "*) echo "pg-backup"; exit 0 ;;
    *) exit 0 ;;
  esac
fi
case "${1:-}" in
  # docker-needs-group가 있으면 docker 그룹을 받은 다시 실행(sg) 전까지 권한이 없는 것처럼 실패한다.
  info) [ -f "$FAKE_STATE_DIR/docker-needs-group" ] && [ "${ACS_DEPLOY_DOCKER_GROUP_REEXEC:-0}" != "1" ] && exit 1; exit 0 ;;
  load) exit 0 ;;
  image) [ -f "$FAKE_STATE_DIR/missing-image" ] && grep -qx "$3" "$FAKE_STATE_DIR/missing-image" && exit 1; exit 0 ;;
  inspect)
    service_name="${!#}"; service_name="${service_name#cid-}"
    [ -f "$FAKE_STATE_DIR/unhealthy-$service_name" ] && echo "unhealthy" || echo "healthy"; exit 0 ;;
esac
exit 0
EOF
# ── 가짜 curl: FAKE_STATE_DIR/executions.json이 있으면 Task 실행 목록으로 답하고, 없으면 Task 서비스가 응답하지 않는 것처럼 실패 ──
cat > "$FAKE_BIN_DIR/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$FAKE_LOG"
output_path=""
request_url=""
previous=""
for argument in "$@"; do
  [ "$previous" = "-o" ] && output_path="$argument"
  previous="$argument"
  case "$argument" in
    *download.docker.com*) exit 7 ;;
    http://*|https://*) request_url="$argument" ;;
  esac
done
# 인터넷은 되는데 배포한 적 없는 채널: 릴리즈 채널 주소는 모두 404(22)
if [ -n "${FAKE_ONLINE_CHANNEL_EMPTY:-}" ] && [[ "$request_url" == https://download.example/* ]]; then
  echo "curl: (22) The requested URL returned error: 404" >&2; exit 22
fi
# 인터넷이 없는 현장: 릴리즈 채널 주소는 모두 연결 실패(6)
if [ -n "${FAKE_ONLINE_OFFLINE:-}" ] && [[ "$request_url" == https://download.example/* || "$request_url" == https://diokjo4dtg1mp.cloudfront.net/* ]]; then
  exit 6
fi
# 서비스별 최신 버전(<채널>/<서비스>/version.json)과 서비스 ZIP(<채널>/<서비스>/<버전>.zip)
if [[ "$request_url" == */version.json ]] && [ -n "${FAKE_ONLINE_SERVICES_DIR:-}" ]; then
  service_name="$(basename "$(dirname "$request_url")")"
  [ -f "$FAKE_ONLINE_SERVICES_DIR/$service_name/version.json" ] || exit 22
  cp "$FAKE_ONLINE_SERVICES_DIR/$service_name/version.json" "$output_path"; exit 0
fi
if [[ "$request_url" =~ /([a-z]+)/([0-9][0-9.]*)\.zip$ ]] && [ -n "${FAKE_ONLINE_SERVICES_DIR:-}" ]; then
  service_package="$FAKE_ONLINE_SERVICES_DIR/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}.zip"
  [ -f "$service_package" ] || exit 22
  cp "$service_package" "$output_path"; exit 0
fi
if [[ "$request_url" == */latest.json ]] && [ -n "${FAKE_ONLINE_MANIFEST:-}" ]; then
  cp "$FAKE_ONLINE_MANIFEST" "$output_path"; exit 0
fi
if [[ "$request_url" == */acs-*-update.zip || "$request_url" == */acs-*-install.zip ]] && [ -n "${FAKE_FAIL_PACKAGE:-}" ] && [ -n "$output_path" ]; then
  echo "partial" > "$output_path"; exit 18
fi
if [[ "$request_url" == */acs-*-update.zip || "$request_url" == */acs-*-install.zip ]] && [ -n "${FAKE_ONLINE_PACKAGE:-}" ]; then
  cp "$FAKE_ONLINE_PACKAGE" "$output_path"; exit 0
fi
# Gateway 갱신 후 조회는 별도 응답 파일 없이 정상으로 답하고, 오류·기동 지연도 재현합니다.
if [[ "$request_url" == */task/execution/executions ]] && [ -f "$FAKE_STATE_DIR/gateway-check-pending" ]; then
  [ -f "$FAKE_STATE_DIR/gateway-api-fails" ] && exit 22
  if [ -f "$FAKE_STATE_DIR/gateway-api-delay" ] && [ ! -f "$FAKE_STATE_DIR/gateway-api-retried" ]; then
    touch "$FAKE_STATE_DIR/gateway-api-retried"; exit 22
  fi
  rm -f "$FAKE_STATE_DIR/gateway-check-pending"
  [ -f "$FAKE_STATE_DIR/executions.json" ] && cat "$FAKE_STATE_DIR/executions.json" || echo '[]'
  exit 0
fi
[ -f "$FAKE_STATE_DIR/executions.json" ] && { cat "$FAKE_STATE_DIR/executions.json"; exit 0; }
exit 7
EOF
chmod +x "$FAKE_BIN_DIR/docker" "$FAKE_BIN_DIR/curl"
# 컨테이너 환경의 인증값이 특수문자까지 그대로 전달되는지 검사하는 백업 명령입니다.
cat > "$FAKE_BIN_DIR/mongodump" <<'EOF'
#!/bin/bash
mongo_user=""
mongo_password=""
authentication_database=""
while [ $# -gt 0 ]; do
  case "$1" in
    --username) mongo_user="$2"; shift 2 ;;
    --password) mongo_password="$2"; shift 2 ;;
    --authenticationDatabase) authentication_database="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ "$mongo_user" = backup_test_admin ] && [ "$mongo_password" = 'Backup@Test!#' ] && [ "$authentication_database" = admin ] || exit 1
echo "mongo-backup"
EOF
chmod +x "$FAKE_BIN_DIR/mongodump"
export PATH="$FAKE_BIN_DIR:$PATH"

# ── 설치 설정 ──
export ACS_ENV_FILE="$TEST_ROOT/etc/acs-env.conf"
# acs 명령 링크는 시험 디렉터리에 만든다(/usr/local/bin을 건드리지 않음).
export ACS_COMMAND_LINK="$TEST_ROOT/bin/acs"
mkdir -p "$TEST_ROOT/bin"
export ACS_ROOT="$TEST_ROOT/rb-acs"
export HEALTH_TIMEOUT_SEC=4
mkdir -p "$(dirname "$ACS_ENV_FILE")"
cat > "$ACS_ENV_FILE" <<EOF
ACS_ROOT="$ACS_ROOT"
ACS_PROJECT="rb-acs-test"
ACS_GATEWAY_URL="http://127.0.0.1:65530"
EOF

# 가짜 릴리즈 ZIP을 만든다. <출력> <버전> <서비스,...> <이미지 태그 또는 -> [smc.conf 내용]
make_release() {
  python3 -I - "$@" <<'PYEOF'
import hashlib, json, os, sys, zipfile
output_path, version, services_csv, image_tag = sys.argv[1:5]
# 서비스 ZIP은 매니페스트 version이 통합 버전이고 서비스 버전은 따로입니다(RELEASE_SERVICE_VERSION).
service_version = os.environ.get("RELEASE_SERVICE_VERSION") or version
# 빌드한 브랜치(RELEASE_BRANCH). 예전 ZIP처럼 없을 수도 있습니다.
release_branch = os.environ.get("RELEASE_BRANCH")
smc_conf = sys.argv[5] if len(sys.argv) > 5 else "listen 13100;\n"
entries = {}
services = {}
for service_name in services_csv.split(","):
    path = f"services/{service_name}/{service_name}.amd64.bin"
    content = f"#!/bin/sh\necho {service_name} {service_version}\n".encode()
    entries[path] = content
    services[service_name] = {"version": service_version, "path": path, "sha256": hashlib.sha256(content).hexdigest()}
runtime_files = {
    "compose.yml": b"services: {}\n", "compose.offline.yml": f"# {version}\n".encode(), ".env": b"TASK_PORT=18002\n",
    "site.env.example": b"# example\nPOSTGRES_PASSWORD=change-me\nFRS_API_BASE_URL=http://192.168.60.200:3000\nSMC_MOMS_URL=http://mock:18006\n",
    "api-gateway/servers/smc.conf": smc_conf.encode(), "zenoh-router-acs/zenoh.json5": b"{}\n",
}
for relative_path, content in runtime_files.items():
    entries[f"runtime/{relative_path}"] = content
images = {"tag": None, "names": [], "archive": None, "sha256": None}
if image_tag != "-":
    entries["images/acs-images.tar"] = b"image-tar"
    images = {"tag": image_tag, "names": [], "archive": "images/acs-images.tar", "sha256": hashlib.sha256(b"image-tar").hexdigest()}
manifest = {
    "kind": "acs.release", "format_version": 1, "version": version, "branch": release_branch, "created_at": "2026-10-30T00:00:00Z", "git_commit": "abc1234",
    "arch": "amd64", "services": services,
    "runtime": {"path": "runtime", "files": {path: hashlib.sha256(content).hexdigest() for path, content in runtime_files.items()}},
    "images": images,
}
with zipfile.ZipFile(output_path, "w") as archive:
    archive.writestr("version.json", json.dumps(manifest))
    for name, content in entries.items():
        archive.writestr(name, content)
PYEOF
}

json_value() {  # <파일> <키 경로(점 구분)>
  python3 -I -c 'import json,sys; value=json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."): value=value[int(key)] if isinstance(value,list) else value.get(key) if isinstance(value,dict) else None
print("" if value is None else value)' "$1" "$2"
}

latest_run() {  # 가장 최근 실행 기록 파일
  ls -t "$ACS_ROOT"/deploy/runs/*.json 2>/dev/null | head -n1
}

assert_equal() {  # <설명> <기대> <실제>
  TEST_COUNT=$((TEST_COUNT + 1))
  if [ "$2" = "$3" ]; then echo "  ✔ $1"; else echo "  ✘ $1: 기대 [$2], 실제 [$3]"; FAILURES=$((FAILURES + 1)); fi
}
assert_true() {  # <설명> <명령...>
  local description=$1; shift
  TEST_COUNT=$((TEST_COUNT + 1))
  if "$@"; then echo "  ✔ $description"; else echo "  ✘ $description"; FAILURES=$((FAILURES + 1)); fi
}
run_update() {  # update.sh 종료 코드를 돌려준다(출력은 숨김).
  bash "$KIT_DIR/update.sh" "$@" >/dev/null 2>&1
  echo $?
}

ALL_SERVICES="common,scenario,task,state,external,map,mock"
make_release "$TEST_ROOT/acs-v1.zip" v1 "$ALL_SERVICES" v1
make_release "$TEST_ROOT/acs-v2-task.zip" v2 task - "listen 13199;\n"
make_release "$TEST_ROOT/acs-v3-state.zip" v3 state -

echo "▶ deploy.sh --no-systemd: 설정 파일·site.env 생성 후 설치"
bash "$KIT_DIR/deploy.sh" --input="$TEST_ROOT/acs-v1.zip" --root="$ACS_ROOT" --project=rb-acs-test --gateway-url=http://127.0.0.1:65530 \
  --frs-url=http://10.0.0.5:3000 --no-systemd > "$TEST_ROOT/deploy.out" 2>&1
assert_equal "deploy.sh 종료 코드" "0" "$?"
assert_true "설정 파일에 설치 디렉터리" grep -q "ACS_ROOT=\"$ACS_ROOT\"" "$ACS_ENV_FILE"
assert_true "site.env에 FRS 주소" grep -qx "FRS_API_BASE_URL=http://10.0.0.5:3000" "$ACS_ROOT/site.env"
assert_true "site.env DB 비밀번호는 예시 값이 아님" bash -c "! grep -qx 'POSTGRES_PASSWORD=change-me' '$ACS_ROOT/site.env'"
assert_equal "site.env 권한" "600" "$(stat -c %a "$ACS_ROOT/site.env")"
assert_equal "설치 버전" "v1" "$(json_value "$ACS_ROOT/deploy/installed.json" version)"
assert_equal "이미지 태그" "v1" "$(json_value "$ACS_ROOT/deploy/installed.json" images_tag)"
assert_equal "상태" "success" "$(json_value "$ACS_ROOT/deploy/status.json" state)"
assert_true ".env에 이미지 태그" grep -qx "ACS_IMAGE_TAG=v1" "$ACS_ROOT/.env"
assert_true "task bin 실행 권한" test -x "$ACS_ROOT/services/task/task.amd64.bin"
assert_true "이미지 load" grep -q "docker load -i" "$FAKE_LOG"
assert_true "최초 설치는 DB 백업을 하지 않음" bash -c "! grep -q mongodump '$FAKE_LOG'"
assert_true "최초 설치는 compose up이 만든 컨테이너를 다시 재시작하지 않음" bash -c "! grep -q ' restart ' '$FAKE_LOG'"
assert_true "최초 설치는 이전 버전 보관본이 없음" bash -c "! ls '$ACS_ROOT'/deploy/archives/*.zip >/dev/null 2>&1"
assert_equal "온라인 자동배포 기본값은 꺼짐" "0" "$(bash -c '. "$1"; echo "$ACS_ONLINE_AUTO_UPDATE"' _ "$ACS_ENV_FILE")"
assert_equal "온라인 기본 채널" "main" "$(bash -c '. "$1"; echo "$ACS_RELEASE_CHANNEL"' _ "$ACS_ENV_FILE")"
assert_equal "온라인 기본 주소" "https://diokjo4dtg1mp.cloudfront.net/acs/main" "$(bash -c '. "$1"; echo "$ACS_RELEASE_BASE_URL"' _ "$ACS_ENV_FILE")"

echo "▶ acs 명령: 설치한 서비스 상태·실행·중지·재시작·로그 (업데이트 중이면 거절)"
: > "$FAKE_LOG"
assert_equal "acs restart 종료 코드" "0" "$(bash "$KIT_DIR/acs.sh" restart task state >/dev/null 2>&1; echo $?)"
assert_true "restart는 설치 compose로 지정 서비스만" grep -q "compose -p rb-acs-test --project-directory $ACS_ROOT .* restart task state" "$FAKE_LOG"
assert_true "compose 파일·env 파일을 업데이트 엔진과 같게" grep -q -- "--env-file $ACS_ROOT/site.env -f $ACS_ROOT/compose.yml -f $ACS_ROOT/compose.offline.yml" "$FAKE_LOG"
bash "$KIT_DIR/acs.sh" start >/dev/null 2>&1
assert_true "start는 up -d" grep -q "compose .* up -d" "$FAKE_LOG"
bash "$KIT_DIR/acs.sh" stop mock >/dev/null 2>&1
assert_true "stop은 지정 서비스만" grep -q "compose .* stop mock" "$FAKE_LOG"
bash "$KIT_DIR/acs.sh" logs task >/dev/null 2>&1
assert_true "logs는 따라가며 마지막 줄부터" grep -q "compose .* logs -f --tail 200 task" "$FAKE_LOG"
acs_status_output="$(bash "$KIT_DIR/acs.sh" 2>&1)"
assert_true "인자 없으면 상태(ps)" grep -q "compose .* ps" "$FAKE_LOG"
assert_true "상태에 설치 버전" grep -q "설치 버전: v1" <<< "$acs_status_output"
assert_equal "모르는 서비스는 사용법 오류(2)" "2" "$(bash "$KIT_DIR/acs.sh" restart nosuch >/dev/null 2>&1; echo $?)"
assert_equal "모르는 명령은 사용법 오류(2)" "2" "$(bash "$KIT_DIR/acs.sh" explode >/dev/null 2>&1; echo $?)"
# 업데이트 엔진이 잠금을 잡고 있는 동안(업데이트 중)에는 실행·중지·재시작을 거절하고, --force면 진행한다.
touch "$ACS_ROOT/deploy/.update.lock"
flock "$ACS_ROOT/deploy/.update.lock" sleep 5 &
update_lock_pid=$!
sleep 0.3
: > "$FAKE_LOG"
assert_equal "업데이트 중 restart는 거절(75)" "75" "$(bash "$KIT_DIR/acs.sh" restart task >/dev/null 2>&1; echo $?)"
assert_true "업데이트 중 restart는 compose를 부르지 않음" bash -c "! grep -q ' restart ' '$FAKE_LOG'"
assert_equal "업데이트 중에도 상태 보기는 됨" "0" "$(bash "$KIT_DIR/acs.sh" status >/dev/null 2>&1; echo $?)"
assert_equal "--force면 업데이트 중에도 진행" "0" "$(bash "$KIT_DIR/acs.sh" restart task --force >/dev/null 2>&1; echo $?)"
# flock이 띄운 sleep이 잠금을 쥐고 있으므로 자식까지 끝낸다.
pkill -P "$update_lock_pid" 2>/dev/null; kill "$update_lock_pid" 2>/dev/null; wait "$update_lock_pid" 2>/dev/null
# deploy.sh가 /usr/local/bin/acs로 연결해 두므로 심볼릭 링크로 불러도 키트 폴더를 찾는다.
ln -sf "$KIT_DIR/acs.sh" "$TEST_ROOT/acs"
: > "$FAKE_LOG"
assert_equal "링크로 불러도 동작" "0" "$(bash "$TEST_ROOT/acs" restart task >/dev/null 2>&1; echo $?)"
assert_true "링크로 불러도 같은 compose" grep -q "restart task" "$FAKE_LOG"

echo "▶ 현장 파일은 업데이트가 덮어쓰지 않음 + Task만 바꾸는 부분 업데이트"
echo "listen 13105; # 현장 수정" > "$ACS_ROOT/api-gateway/servers/smc.conf"
: > "$FAKE_LOG"
assert_equal "v2(task) 적용 종료 코드" "0" "$(run_update "$TEST_ROOT/acs-v2-task.zip")"
assert_true "task bin은 v2" grep -q "task v2" "$ACS_ROOT/services/task/task.amd64.bin"
assert_true "state bin은 v1 그대로" grep -q "state v1" "$ACS_ROOT/services/state/state.amd64.bin"
assert_equal "서비스별 버전(task)" "v2" "$(json_value "$ACS_ROOT/deploy/installed.json" services.task.version)"
assert_equal "서비스별 버전(state)" "v1" "$(json_value "$ACS_ROOT/deploy/installed.json" services.state.version)"
assert_equal "이미지 없는 ZIP은 설치된 이미지 태그 유지" "v1" "$(json_value "$ACS_ROOT/deploy/installed.json" images_tag)"
assert_true "현장 서버 블록 보존" grep -q "현장 수정" "$ACS_ROOT/api-gateway/servers/smc.conf"
assert_true "업데이트 전 DB 백업" bash -c "ls '$ACS_ROOT'/backups/*-v2/mongo.archive.gz >/dev/null"
assert_true "task 재시작" grep -q "restart task" "$FAKE_LOG"
assert_true "바뀐 설정이 없으면 Gateway 재시작 안 함" bash -c "! grep -q 'restart task api-gateway' '$FAKE_LOG'"
cli_run="$(latest_run)"
assert_equal "직접 실행 출처" "cli" "$(json_value "$cli_run" source)"
assert_equal "직접 실행 결과" "success" "$(json_value "$cli_run" result)"
assert_equal "실행 기록 버전" "v2" "$(json_value "$cli_run" version)"
assert_equal "단계 진행(validate → … → done)" "validate images backup snapshot runtime swap restart health done" \
  "$(python3 -I -c 'import json,sys; print(" ".join(stage["stage"] for stage in json.load(open(sys.argv[1]))["stages"]))' "$cli_run")"
assert_true "끝난 단계에 끝난 시각" test -n "$(json_value "$cli_run" stages.0.ended_at)"
assert_equal "이력에 실행 ID" "$(json_value "$cli_run" run_id)" "$(json_value "$ACS_ROOT/deploy/installed.json" history.-1.run_id)"
assert_equal "이력에 출처" "cli" "$(json_value "$ACS_ROOT/deploy/installed.json" history.-1.source)"

echo "▶ 업데이트 전 상태를 버전을 적은 보관본 ZIP으로 남기고, 그 ZIP으로 되돌릴 수 있음"
snapshot_path="$(ls "$ACS_ROOT"/deploy/archives/acs-rollback-v1-before-v2-*.zip 2>/dev/null | head -n1)"
assert_true "보관본 ZIP 생성(이름에 이전·새 버전)" test -n "$snapshot_path"
snapshot_staging="$TEST_ROOT/snapshot-check"
python3 -I "$KIT_DIR/release.py" extract "$snapshot_path" "$snapshot_staging"
assert_true "보관본은 그대로 적용할 수 있는 릴리즈 ZIP" python3 -I "$KIT_DIR/release.py" validate "$snapshot_staging" amd64
assert_equal "보관본 버전은 이전 설치 버전" "v1" "$(json_value "$snapshot_staging/version.json" version)"
assert_equal "보관본에 담은 서비스(바뀐 서비스만)" "task" "$(python3 -I "$KIT_DIR/release.py" get "$snapshot_staging" services)"
assert_equal "보관본 task 서비스 버전" "v1" "$(json_value "$snapshot_staging/version.json" services.task.version)"
assert_equal "어느 버전 적용 전인지" "v2" "$(json_value "$snapshot_staging/version.json" snapshot.replaced_by)"
assert_true "보관본 task bin은 이전 내용" grep -q "task v1" "$snapshot_staging/services/task/task.amd64.bin"
assert_true "보관본 .env에는 이미지 태그를 넣지 않음(적용할 때 엔진이 붙임)" bash -c "! grep -q '^ACS_IMAGE_TAG=' '$snapshot_staging/runtime/.env'"
cp "$snapshot_path" "$TEST_ROOT/acs-v1-snapshot.zip"
assert_equal "보관본으로 되돌리기 종료 코드" "0" "$(run_update "$TEST_ROOT/acs-v1-snapshot.zip")"
assert_true "task bin이 v1로 돌아옴" grep -q "task v1" "$ACS_ROOT/services/task/task.amd64.bin"
assert_equal "되돌린 뒤 task 버전" "v1" "$(json_value "$ACS_ROOT/deploy/installed.json" services.task.version)"
assert_true "되돌리기 전 상태(v2)도 다시 보관" bash -c "ls '$ACS_ROOT'/deploy/archives/acs-rollback-v2-before-v1-*.zip >/dev/null 2>&1"
assert_equal "다시 v2 적용" "0" "$(run_update "$TEST_ROOT/acs-v2-task.zip")"

echo "▶ 설정 파일이 그대로면 compose up 없이 바뀐 서비스만 재시작"
: > "$FAKE_LOG"
assert_equal "같은 설정으로 v2(task) 다시 적용" "0" "$(run_update "$TEST_ROOT/acs-v2-task.zip")"
assert_true "compose up 생략" bash -c "! grep -q ' up ' '$FAKE_LOG'"
assert_true "task만 재시작" grep -q "restart task$" "$FAKE_LOG"
assert_true "로그에 생략 이유" grep -q "compose up을 건너뜁니다" "$ACS_ROOT/deploy/update.log"

echo "MongoDB 백업 인증: 기존 컨테이너 환경값 사용과 실패 시 교체 중단"
touch "$FAKE_STATE_DIR/mongo-auth-required"
: > "$FAKE_LOG"
assert_equal "인증이 필요한 MongoDB 백업도 업데이트 성공" "0" "$(run_update "$TEST_ROOT/acs-v2-task.zip")"
assert_true "관리자 이름은 컨테이너 환경에서 읽음" grep -Fq -- '--username "$MONGO_INITDB_ROOT_USERNAME"' "$FAKE_LOG"
assert_true "관리자 비밀번호는 컨테이너 환경에서 읽음" grep -Fq -- '--password "$MONGO_INITDB_ROOT_PASSWORD"' "$FAKE_LOG"
assert_true "MongoDB 관리자 인증 DB 지정" grep -Fq -- '--authenticationDatabase admin' "$FAKE_LOG"
assert_true "특수문자가 포함된 비밀번호는 로그에 출력하지 않음" bash -c '! grep -Fq -- "Backup@Test!#" "$1" "$2"' _ "$FAKE_LOG" "$ACS_ROOT/deploy/update.log"
cp "$ACS_ROOT/site.env" "$TEST_ROOT/site-before-mongo-failure.env"
touch "$FAKE_STATE_DIR/mongo-backup-fails"
: > "$FAKE_LOG"
assert_equal "MongoDB 백업 실패 종료 코드" "1" "$(run_update "$TEST_ROOT/acs-v3-state.zip")"
assert_equal "MongoDB 백업 실패 단계" "backup" "$(json_value "$ACS_ROOT/deploy/status.json" stage)"
assert_true "백업 실패 시 서비스 bin 보존" grep -q "state v1" "$ACS_ROOT/services/state/state.amd64.bin"
assert_true "백업 실패 시 현장 환경설정 보존" cmp -s "$TEST_ROOT/site-before-mongo-failure.env" "$ACS_ROOT/site.env"
assert_true "백업 실패 시 서비스 재기동 없음" bash -c '! grep -Eq " (restart|up) " "$1"' _ "$FAKE_LOG"
rm -f "$FAKE_STATE_DIR/mongo-auth-required" "$FAKE_STATE_DIR/mongo-backup-fails"

echo "Gateway 갱신: 서비스 준비 후 주소 재조회와 실제 조회 응답 확인"
: > "$FAKE_LOG"
assert_equal "Gateway 갱신을 포함한 업데이트 성공" "0" "$(run_update "$TEST_ROOT/acs-v2-task.zip")"
assert_true "Gateway 설정 검사" grep -q 'exec -T api-gateway nginx -t' "$FAKE_LOG"
assert_true "Gateway 설정 reload" grep -q 'exec -T api-gateway nginx -s reload' "$FAKE_LOG"
assert_true "서비스 상태 확인 후 검사·reload·API 조회 순서" python3 -I -c 'import sys
commands=open(sys.argv[1]).read().splitlines()
health=max(position for position,command in enumerate(commands) if "docker inspect " in command)
check=next(position for position,command in enumerate(commands) if "exec -T api-gateway nginx -t" in command)
reload=next(position for position,command in enumerate(commands) if "exec -T api-gateway nginx -s reload" in command)
query=max(position for position,command in enumerate(commands) if "curl " in command and "/task/execution/executions" in command)
assert health < check < reload < query' "$FAKE_LOG"
touch "$FAKE_STATE_DIR/gateway-api-delay"
assert_equal "Gateway 갱신 직후 일시적인 502는 재확인" "0" "$(run_update "$TEST_ROOT/acs-v2-task.zip")"
assert_true "일시적인 API 오류 뒤 재시도" test -f "$FAKE_STATE_DIR/gateway-api-retried"
rm -f "$FAKE_STATE_DIR/gateway-api-delay" "$FAKE_STATE_DIR/gateway-api-retried"
cp "$ACS_ROOT/services/state/state.amd64.bin" "$TEST_ROOT/state-before-gateway.bin"
cp "$ACS_ROOT/deploy/installed.json" "$TEST_ROOT/installed-before-gateway.json"
for failure in config reload api; do
  touch "$FAKE_STATE_DIR/gateway-$failure-fails"
  : > "$FAKE_LOG"
  assert_equal "Gateway $failure 실패 종료 코드" "1" "$(run_update "$TEST_ROOT/acs-v3-state.zip")"
  assert_equal "Gateway $failure 실패는 기존 복구 처리" "rollback" "$(json_value "$ACS_ROOT/deploy/status.json" stage)"
  assert_true "Gateway $failure 실패 시 이전 bin 복원" grep -q "state v1" "$ACS_ROOT/services/state/state.amd64.bin"
  assert_equal "Gateway $failure 실패 시 설치 버전 보존" "v2" "$(json_value "$ACS_ROOT/deploy/installed.json" version)"
  rm -f "$FAKE_STATE_DIR/gateway-$failure-fails" "$FAKE_STATE_DIR/gateway-check-pending"
  cp "$TEST_ROOT/state-before-gateway.bin" "$ACS_ROOT/services/state/state.amd64.bin"
  cp "$TEST_ROOT/installed-before-gateway.json" "$ACS_ROOT/deploy/installed.json"
done

echo "▶ sha256이 맞지 않으면 아무것도 바꾸지 않음"
python3 -I - "$TEST_ROOT/acs-v3-state.zip" "$TEST_ROOT/acs-v3-broken.zip" <<'PYEOF'
import json, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as source, zipfile.ZipFile(sys.argv[2], "w") as target:
    for item in source.infolist():
        content = source.read(item.filename)
        if item.filename.endswith("state.amd64.bin"):
            content += b"tampered"
        target.writestr(item, content)
PYEOF
assert_equal "손상 ZIP 종료 코드" "1" "$(run_update "$TEST_ROOT/acs-v3-broken.zip")"
assert_equal "실패 상태" "failed" "$(json_value "$ACS_ROOT/deploy/status.json" state)"
assert_true "실패 메시지에 sha256" grep -q "sha256" "$ACS_ROOT/deploy/status.json"
assert_true "state bin은 v1 그대로" grep -q "state v1" "$ACS_ROOT/services/state/state.amd64.bin"
assert_equal "실패 이력" "failed" "$(json_value "$ACS_ROOT/deploy/installed.json" history.-1.result)"
failed_run="$(latest_run)"
assert_equal "실패 실행 결과" "failed" "$(json_value "$failed_run" result)"
assert_equal "멈춘 단계" "validate" "$(json_value "$failed_run" stopped_stage)"
failed_error="$(python3 -I -c 'import json,sys; print(" ".join(note["message"] for note in json.load(open(sys.argv[1]))["notes"] if note["level"] == "error"))' "$failed_run")"
assert_true "에러 기록에 sha256" bash -c "echo '$failed_error' | grep -q sha256"
assert_equal "Task 서비스 무응답은 경고로 기록" "warning" "$(json_value "$failed_run" notes.0.level)"

echo "▶ 실행 중인 Task가 있으면 대기(75), 강제 적용은 진행"
echo '[{"state":"running"},{"state":"completed"}]' > "$FAKE_STATE_DIR/executions.json"
assert_equal "대기 종료 코드" "75" "$(run_update "$TEST_ROOT/acs-v3-state.zip")"
assert_equal "대기 상태" "waiting" "$(json_value "$ACS_ROOT/deploy/status.json" state)"
assert_true "대기 메시지에 Task 수" grep -q "Task 1개" "$ACS_ROOT/deploy/status.json"
assert_true "state bin은 v1 그대로" grep -q "state v1" "$ACS_ROOT/services/state/state.amd64.bin"
assert_equal "강제 적용 종료 코드" "0" "$(run_update --force "$TEST_ROOT/acs-v3-state.zip")"
assert_true "state bin은 v3" grep -q "state v3" "$ACS_ROOT/services/state/state.amd64.bin"
rm -f "$FAKE_STATE_DIR/executions.json"

echo "▶ 헬스체크 실패 시 bin·설정을 되돌림"
make_release "$TEST_ROOT/acs-v4-task.zip" v4 task -
touch "$FAKE_STATE_DIR/unhealthy-task"
assert_equal "헬스체크 실패 종료 코드" "1" "$(run_update "$TEST_ROOT/acs-v4-task.zip")"
assert_true "task bin은 v2로 되돌림" grep -q "task v2" "$ACS_ROOT/services/task/task.amd64.bin"
assert_equal "실패 단계" "rollback" "$(json_value "$ACS_ROOT/deploy/status.json" stage)"
assert_true "실패 메시지에 서비스" grep -q "task:unhealthy" "$ACS_ROOT/deploy/status.json"
assert_equal "설치 버전은 그대로" "v3" "$(json_value "$ACS_ROOT/deploy/installed.json" version)"
assert_equal "되돌린 실행의 멈춘 단계는 health" "health" "$(json_value "$(latest_run)" stopped_stage)"
rm -f "$FAKE_STATE_DIR/unhealthy-task"

echo "▶ 필요한 이미지가 없으면 바꾸기 전에 멈춤"
echo "mongo:7" > "$FAKE_STATE_DIR/missing-image"
assert_equal "이미지 없음 종료 코드" "1" "$(run_update "$TEST_ROOT/acs-v4-task.zip")"
assert_true "이미지 없음 메시지" grep -q "mongo:7" "$ACS_ROOT/deploy/status.json"
assert_true "task bin은 v2 그대로" grep -q "task v2" "$ACS_ROOT/services/task/task.amd64.bin"
rm -f "$FAKE_STATE_DIR/missing-image"

echo "▶ observer: 성공 ZIP은 지우고, 대기 ZIP은 두고, 실패 ZIP은 failed/로"
echo '{"source": "ui-upload"}' > "$ACS_ROOT/deploy/observe/acs-v4-task.zip.meta.json"
cp "$TEST_ROOT/acs-v4-task.zip" "$ACS_ROOT/deploy/observe/acs-v4-task.zip"
echo '{"archive_keep_count": 1}' > "$ACS_ROOT/deploy/settings.json"
bash "$KIT_DIR/observer.sh" --once >/dev/null 2>&1
assert_true "적용한 ZIP 삭제" test ! -e "$ACS_ROOT/deploy/observe/acs-v4-task.zip"
assert_true "적용한 ZIP의 출처 파일 삭제" test ! -e "$ACS_ROOT/deploy/observe/acs-v4-task.zip.meta.json"
assert_equal "UI 업로드 출처" "ui-upload" "$(json_value "$(latest_run)" source)"
assert_equal "정책 보관 개수(1)만 남김" "1" "$(ls "$ACS_ROOT"/deploy/archives/acs-rollback-*.zip | wc -l | tr -d ' ')"
rm -f "$ACS_ROOT/deploy/settings.json"
assert_true "task bin은 v4" grep -q "task v4" "$ACS_ROOT/services/task/task.amd64.bin"
assert_true "heartbeat 기록" test -f "$ACS_ROOT/deploy/observer.json"
assert_equal "observer가 acs 명령 링크를 키트로 맞춤(이미 설치한 현장)" "$KIT_DIR/acs.sh" "$(readlink -f "$ACS_COMMAND_LINK")"
assert_true "heartbeat에 온라인 요청 처리 가능 표시(예전 키트와 구분)" grep -q '"online"' "$ACS_ROOT/deploy/observer.json"
echo '[{"state":"action_required"}]' > "$FAKE_STATE_DIR/executions.json"
make_release "$TEST_ROOT/acs-v5-task.zip" v5 task -
cp "$TEST_ROOT/acs-v5-task.zip" "$ACS_ROOT/deploy/observe/acs-v5-task.zip"
bash "$KIT_DIR/observer.sh" --once >/dev/null 2>&1
assert_true "대기 ZIP은 남김" test -f "$ACS_ROOT/deploy/observe/acs-v5-task.zip"
assert_equal "observer 대기 상태" "waiting" "$(json_value "$ACS_ROOT/deploy/status.json" state)"
waiting_run_id="$(json_value "$ACS_ROOT/deploy/observe/acs-v5-task.zip.meta.json" run_id)"
assert_equal "직접 넣은 ZIP 출처" "offline-file" "$(json_value "$ACS_ROOT/deploy/runs/$waiting_run_id.json" source)"
assert_equal "대기 중 실행 결과" "waiting" "$(json_value "$ACS_ROOT/deploy/runs/$waiting_run_id.json" result)"
touch "$ACS_ROOT/deploy/observe/acs-v5-task.zip.force"
bash "$KIT_DIR/observer.sh" --once >/dev/null 2>&1
assert_true "강제 표시가 있으면 적용" grep -q "task v5" "$ACS_ROOT/services/task/task.amd64.bin"
assert_equal "대기 뒤 적용은 같은 실행 기록에 이어서" "success" "$(json_value "$ACS_ROOT/deploy/runs/$waiting_run_id.json" result)"
assert_equal "감지부터 남음" "detected" "$(json_value "$ACS_ROOT/deploy/runs/$waiting_run_id.json" stages.0.stage)"
assert_equal "대기 단계 기록" "wait_tasks" "$(json_value "$ACS_ROOT/deploy/runs/$waiting_run_id.json" stages.1.stage)"
assert_true "강제 표시 삭제" test ! -e "$ACS_ROOT/deploy/observe/acs-v5-task.zip.force"
rm -f "$FAKE_STATE_DIR/executions.json"
cp "$TEST_ROOT/acs-v3-broken.zip" "$ACS_ROOT/deploy/observe/acs-v3-broken.zip"
bash "$KIT_DIR/observer.sh" --once >/dev/null 2>&1
assert_true "실패 ZIP은 failed/로" test -f "$ACS_ROOT/deploy/failed/acs-v3-broken.zip"
assert_true "실패 ZIP은 observe/에서 빠짐" test ! -e "$ACS_ROOT/deploy/observe/acs-v3-broken.zip"
assert_equal "status의 ZIP 이름은 원래 이름" "acs-v3-broken.zip" "$(json_value "$ACS_ROOT/deploy/status.json" package)"
# 엔진이 단계 기록 없이 죽어도(옵션·설정 오류 등) failed/로 옮긴 이유가 실행 기록·상태·update.log에 남아야 한다.
cat > "$TEST_ROOT/dying-update.sh" <<'EOF'
#!/bin/bash
echo "알 수 없는 옵션: --weird" >&2
exit 2
EOF
cp "$TEST_ROOT/acs-v5-task.zip" "$ACS_ROOT/deploy/observe/acs-v5-silent.zip"
ACS_UPDATE_SCRIPT="$TEST_ROOT/dying-update.sh" bash "$KIT_DIR/observer.sh" --once >/dev/null 2>&1
assert_true "기록 없이 죽은 ZIP도 failed/로" test -f "$ACS_ROOT/deploy/failed/acs-v5-silent.zip"
assert_equal "기록 없이 죽어도 실행 결과는 실패" "failed" "$(json_value "$(latest_run)" result)"
assert_true "실패 이유에 종료 코드와 stderr" bash -c "grep -q '종료 코드 2' '$(latest_run)' && grep -q '알 수 없는 옵션' '$(latest_run)'"
assert_equal "상태도 실패" "failed" "$(json_value "$ACS_ROOT/deploy/status.json" state)"
assert_true "update.log에도 이유" grep -q "acs-v5-silent.zip: 업데이트 엔진이 이유를 남기지 않고" "$ACS_ROOT/deploy/update.log"
assert_true "stderr 임시 파일 정리" test ! -e "$ACS_ROOT/deploy/.update-stderr.log"

echo "▶ 온라인 자동배포: 기본은 최신 버전 조회만 하고, 명시적으로 켜면 새 버전만 검증 후 적용"
make_release "$TEST_ROOT/acs-v6-task-update.zip" 6.0.0 task -
export FAKE_ONLINE_PACKAGE="$TEST_ROOT/acs-v6-task-update.zip"
export FAKE_ONLINE_MANIFEST="$TEST_ROOT/latest.json"
online_sha="$(sha256sum "$FAKE_ONLINE_PACKAGE" | cut -d' ' -f1)"
cat > "$FAKE_ONLINE_MANIFEST" <<EOF
{"kind":"acs.online-release","format_version":1,"version":"6.0.0","update":{"path":"update/6.0.0/acs-v6-task-update.zip","sha256":"$online_sha"}}
EOF
: > "$FAKE_LOG"
bash "$KIT_DIR/observer.sh" --once >/dev/null 2>&1
assert_true "기본 설정에서도 최신 버전은 조회(버전 탭 표시)" grep -q "latest.json" "$FAKE_LOG"
assert_equal "조회한 최신 전체 버전" "6.0.0" "$(json_value "$ACS_ROOT/deploy/online.json" total.version)"
assert_equal "새 버전 표시" "True" "$(json_value "$ACS_ROOT/deploy/online.json" total.newer)"
assert_equal "자동 업데이트 꺼짐(현장 설정)" "False" "$(json_value "$ACS_ROOT/deploy/online.json" auto_update)"
assert_true "기본 설정에서는 온라인 버전을 적용하지 않음" grep -q "task v5" "$ACS_ROOT/services/task/task.amd64.bin"
assert_equal "자동배포가 꺼져 있어도 --online 수동 적용" "0" "$(run_update --online)"
assert_true "수동 온라인 새 버전 적용" grep -q "task 6.0.0" "$ACS_ROOT/services/task/task.amd64.bin"
assert_equal "수동 온라인 출처" "online-manual" "$(json_value "$(latest_run)" source)"
assert_true "다운로드 완료와 걸린 시간 출력" grep -q "acs-v6-task-update.zip 완료" "$ACS_ROOT/deploy/update.log"
: > "$FAKE_LOG"
assert_equal "같은 버전이면 수동 온라인 업데이트는 받지 않고 끝" "0" "$(run_update --online)"
assert_true "같은 버전이면 ZIP을 받지 않음" bash -c "! grep -q 'acs-v6-task-update.zip' '$FAKE_LOG'"
assert_true "받은 파일을 남기지 않음" bash -c "! ls -A '$ACS_ROOT/deploy' | grep -q 'manual-online'"

make_release "$TEST_ROOT/acs-v7-task-update.zip" 7.0.0 task -
export FAKE_ONLINE_PACKAGE="$TEST_ROOT/acs-v7-task-update.zip"
online_sha="$(sha256sum "$FAKE_ONLINE_PACKAGE" | cut -d' ' -f1)"
cat > "$FAKE_ONLINE_MANIFEST" <<EOF
{"kind":"acs.online-release","format_version":1,"version":"7.0.0","update":{"path":"update/7.0.0/acs-v7-task-update.zip","sha256":"$online_sha"}}
EOF
cat >> "$ACS_ENV_FILE" <<EOF
ACS_ONLINE_AUTO_UPDATE="1"
ACS_RELEASE_BASE_URL="https://download.example/acs/releases"
EOF
bash "$KIT_DIR/observer.sh" --once >/dev/null 2>&1
assert_true "온라인 latest.json 조회" grep -q "latest.json" "$FAKE_LOG"
assert_true "온라인 ZIP 다운로드" grep -q "acs-v7-task-update.zip" "$FAKE_LOG"
assert_true "온라인 새 버전 적용" grep -q "task 7.0.0" "$ACS_ROOT/services/task/task.amd64.bin"
assert_equal "온라인 적용 버전 기록" "7.0.0" "$(json_value "$ACS_ROOT/deploy/installed.json" version)"
assert_equal "온라인 자동 출처" "online-auto" "$(json_value "$(latest_run)" source)"

echo "▶ 버전 탭 온라인: 서비스별 최신 버전 표시, UI 요청으로 서비스·전체 업데이트, 자동 업데이트 켜고 끄기"
export FAKE_ONLINE_SERVICES_DIR="$TEST_ROOT/online-services"
mkdir -p "$FAKE_ONLINE_SERVICES_DIR/task" "$FAKE_ONLINE_SERVICES_DIR/state"
RELEASE_BRANCH=develop RELEASE_SERVICE_VERSION=7.1.0 make_release "$FAKE_ONLINE_SERVICES_DIR/task/7.1.0.zip" 7.0.0 task -
echo '{"new_version": "7.1.0", "git_commit": "abc1234"}' > "$FAKE_ONLINE_SERVICES_DIR/task/version.json"
echo '{"new_version": "3.0.0", "git_commit": "abc1234"}' > "$FAKE_ONLINE_SERVICES_DIR/state/version.json"
# 버전 탭에서 자동 업데이트를 끄면 현장 설정(ACS_ONLINE_AUTO_UPDATE=1)보다 우선한다.
echo '{"enabled": false}' > "$ACS_ROOT/deploy/auto-update.json"
bash "$KIT_DIR/observer.sh" --once >/dev/null 2>&1
observer_output="$(bash "$KIT_DIR/observer.sh" --once 2>&1)"
assert_true "온라인 확인 결과를 observer 로그에 한 줄로" bash -c 'grep -F "온라인 버전 확인" <<< "$1" | grep -qF "새 버전 서비스: task 7.1.0"' _ "$observer_output"
assert_equal "서비스 최신 버전" "7.1.0" "$(json_value "$ACS_ROOT/deploy/online.json" services.task.version)"
assert_equal "서비스 새 버전 표시" "True" "$(json_value "$ACS_ROOT/deploy/online.json" services.task.newer)"
assert_equal "같은 버전 서비스는 새 버전 아님" "False" "$(json_value "$ACS_ROOT/deploy/online.json" services.state.newer)"
assert_equal "서비스 ZIP 경로" "task/7.1.0.zip" "$(json_value "$ACS_ROOT/deploy/online.json" services.task.path)"
assert_equal "UI에서 끈 자동 업데이트" "False" "$(json_value "$ACS_ROOT/deploy/online.json" auto_update)"
assert_equal "자동 업데이트 설정 출처" "ui" "$(json_value "$ACS_ROOT/deploy/online.json" auto_update_source)"
assert_true "자동 업데이트를 끄면 새 서비스 버전도 적용하지 않음" grep -q "task 7.0.0" "$ACS_ROOT/services/task/task.amd64.bin"

mkdir -p "$ACS_ROOT/deploy/requests"
echo '{"kind": "update", "target": "task", "force": false}' > "$ACS_ROOT/deploy/requests/1000-update.json"
bash "$KIT_DIR/observer.sh" --once >/dev/null 2>&1
assert_true "UI 요청으로 task만 온라인 업데이트" grep -q "task 7.1.0" "$ACS_ROOT/services/task/task.amd64.bin"
assert_true "다른 서비스는 그대로" grep -q "state v3" "$ACS_ROOT/services/state/state.amd64.bin"
assert_equal "서비스 업데이트 뒤 전체 버전은 통합 버전 그대로" "7.0.0" "$(json_value "$ACS_ROOT/deploy/installed.json" version)"
assert_equal "설치 브랜치 기록" "develop" "$(json_value "$ACS_ROOT/deploy/installed.json" branch)"
assert_equal "서비스별 브랜치 기록" "develop" "$(json_value "$ACS_ROOT/deploy/installed.json" services.task.branch)"
assert_equal "바꾸지 않은 서비스는 브랜치 모름(예전 ZIP)" "" "$(json_value "$ACS_ROOT/deploy/installed.json" services.state.branch)"
assert_true "acs version에 브랜치" bash -c "bash '$KIT_DIR/acs.sh' version | grep -q '설치 버전: 7.0.0 (develop)'"
assert_equal "UI 온라인 출처" "ui-online" "$(json_value "$(latest_run)" source)"
assert_equal "다운로드 단계부터 기록" "download" "$(json_value "$(latest_run)" stages.0.stage)"
assert_true "처리한 요청 삭제" test ! -e "$ACS_ROOT/deploy/requests/1000-update.json"
assert_equal "적용 뒤 바로 다시 조회해 새 버전 표시를 끔" "False" "$(json_value "$ACS_ROOT/deploy/online.json" services.task.newer)"

# 예전 키트가 처리하지 못해 오래 남은 업데이트 요청은 키트를 바꾼 뒤 뜻밖에 적용되지 않게 버린다(다시 확인 요청은 해롭지 않아 처리).
echo '{"kind": "update", "target": "task", "force": false, "requested_at": 1000}' > "$ACS_ROOT/deploy/requests/0999-update.json"
echo '{"kind": "check"}' > "$ACS_ROOT/deploy/requests/1001-check.json"
: > "$FAKE_LOG"
bash "$KIT_DIR/observer.sh" --once >/dev/null 2>&1
assert_true "다시 확인 요청은 바로 조회" grep -q "task/version.json" "$FAKE_LOG"
assert_true "확인 요청 삭제" test ! -e "$ACS_ROOT/deploy/requests/1001-check.json"
assert_true "오래된 업데이트 요청은 버림" test ! -e "$ACS_ROOT/deploy/requests/0999-update.json"
assert_true "오래된 업데이트 요청은 적용하지 않음" grep -q "task 7.1.0" "$ACS_ROOT/services/task/task.amd64.bin"

# sha256이 있는 서비스 version.json이면 받은 ZIP을 검증한다.
RELEASE_SERVICE_VERSION=7.2.0 make_release "$FAKE_ONLINE_SERVICES_DIR/task/7.2.0.zip" 7.0.0 task -
echo '{"new_version": "7.2.0", "sha256": "0000000000000000000000000000000000000000000000000000000000000000"}' > "$FAKE_ONLINE_SERVICES_DIR/task/version.json"
echo '{"kind": "check"}' > "$ACS_ROOT/deploy/requests/1002-check.json"
echo '{"kind": "update", "target": "task", "force": true}' > "$ACS_ROOT/deploy/requests/1003-update.json"
bash "$KIT_DIR/observer.sh" --once >/dev/null 2>&1
assert_equal "sha256이 다르면 실패" "failed" "$(json_value "$ACS_ROOT/deploy/status.json" state)"
assert_true "sha256이 다르면 적용하지 않음" grep -q "task 7.1.0" "$ACS_ROOT/services/task/task.amd64.bin"
assert_true "sha256이 다른 ZIP은 남기지 않음" bash -c "! ls '$ACS_ROOT'/deploy/observe/ | grep -q ."
assert_equal "실패도 실행 기록에" "failed" "$(json_value "$(latest_run)" result)"

# 자동 업데이트를 켜면 새 서비스 버전을 스스로 받아 적용한다.
task_sha="$(sha256sum "$FAKE_ONLINE_SERVICES_DIR/task/7.2.0.zip" | cut -d' ' -f1)"
echo "{\"new_version\": \"7.2.0\", \"sha256\": \"$task_sha\"}" > "$FAKE_ONLINE_SERVICES_DIR/task/version.json"
echo '{"enabled": true}' > "$ACS_ROOT/deploy/auto-update.json"
bash "$KIT_DIR/observer.sh" --once >/dev/null 2>&1
assert_true "자동 업데이트를 켜면 새 서비스 버전 적용" grep -q "task 7.2.0" "$ACS_ROOT/services/task/task.amd64.bin"
assert_equal "자동 업데이트 출처" "online-auto" "$(json_value "$(latest_run)" source)"
: > "$FAKE_LOG"
bash "$KIT_DIR/observer.sh" --once >/dev/null 2>&1
assert_true "같은 버전은 다시 받지 않음" bash -c "! grep -q '7.2.0.zip' '$FAKE_LOG'"

# 인터넷이 없으면 짧게 포기하고 연결 안 됨을 남긴다(observer 주기를 오래 막지 않음).
: > "$FAKE_LOG"
FAKE_ONLINE_OFFLINE=1 bash "$KIT_DIR/observer.sh" --once >/dev/null 2>&1
assert_equal "인터넷 없음 표시" "False" "$(json_value "$ACS_ROOT/deploy/online.json" reachable)"
assert_true "연결 오류 이유" test -n "$(json_value "$ACS_ROOT/deploy/online.json" error)"
assert_true "두 번 실패하면 나머지 서비스는 묻지 않음" test "$(grep -c 'download.example' "$FAKE_LOG")" -le 2
assert_equal "연결 실패는 network" "network" "$(json_value "$ACS_ROOT/deploy/online.json" error_kind)"
# 인터넷은 되는데 그 채널에 배포한 적이 없으면(404) 연결 실패와 구분한다.
FAKE_ONLINE_CHANNEL_EMPTY=1 bash "$KIT_DIR/observer.sh" --once >/dev/null 2>&1
assert_equal "404만 나면 채널 비어 있음" "channel_empty" "$(json_value "$ACS_ROOT/deploy/online.json" error_kind)"
# 온라인 조회를 끈 현장(ACS_ONLINE_CHECK=0)은 네트워크를 쓰지 않는다.
: > "$FAKE_LOG"
ACS_ONLINE_CHECK=0 bash "$KIT_DIR/observer.sh" --once >/dev/null 2>&1
assert_true "온라인 조회를 끄면 조회하지 않음" bash -c "! grep -q 'download.example' '$FAKE_LOG'"
rm -f "$ACS_ROOT/deploy/auto-update.json"
unset FAKE_ONLINE_SERVICES_DIR

echo "▶ deploy.sh(기본 온라인): --input 없이 최신 설치용 ZIP을 받아 최초 설치"
online_install_root="$TEST_ROOT/rb-acs-online"
online_install_env="$TEST_ROOT/etc/acs-online-env.conf"
make_release "$TEST_ROOT/acs-v8-install.zip" 8.0.0 "$ALL_SERVICES" v8
export FAKE_ONLINE_PACKAGE="$TEST_ROOT/acs-v8-install.zip"
online_sha="$(sha256sum "$FAKE_ONLINE_PACKAGE" | cut -d' ' -f1)"
cat > "$FAKE_ONLINE_MANIFEST" <<EOF
{"kind":"acs.online-release","format_version":1,"version":"8.0.0","deploy":{"path":"deploy/8.0.0/acs-v8-install.zip","sha256":"$online_sha"},"update":{"path":"update/8.0.0/acs-v8-update.zip","sha256":"$online_sha"}}
EOF
ACS_ENV_FILE="$online_install_env" bash "$KIT_DIR/deploy.sh" --mode=develop --root="$online_install_root" \
  --project=rb-acs-online-test --frs-url=http://10.0.0.5:3000 --no-systemd >/dev/null 2>&1
assert_equal "온라인 최초 설치 종료 코드" "0" "$?"
assert_equal "온라인 최초 설치 버전" "8.0.0" "$(json_value "$online_install_root/deploy/installed.json" version)"
assert_true "온라인 최초 설치는 install ZIP 다운로드" grep -q "acs-v8-install.zip" "$FAKE_LOG"
assert_true "--mode=develop은 develop 채널 latest.json" grep -q "acs/develop/latest.json" "$FAKE_LOG"
assert_true "설치 뒤 받은 ZIP을 지움" test ! -e "$online_install_root/.download"
: > "$FAKE_LOG"
ACS_ENV_FILE="$online_install_env" bash "$KIT_DIR/deploy.sh" --root="$online_install_root" \
  --project=rb-acs-online-test --no-systemd >/dev/null 2>&1
assert_equal "이미 최신이면 deploy.sh 종료 코드" "0" "$?"
assert_true "이미 최신이면 설치 ZIP을 받지 않음" bash -c "! grep -q 'acs-v8-install.zip' '$FAKE_LOG'"
: > "$FAKE_LOG"
ACS_ENV_FILE="$online_install_env" bash "$KIT_DIR/deploy.sh" --root="$online_install_root" \
  --project=rb-acs-online-test --reinstall --no-systemd >/dev/null 2>&1
assert_true "--reinstall이면 같은 버전도 다시 받음" grep -q "acs-v8-install.zip" "$FAKE_LOG"
failed_install_root="$TEST_ROOT/rb-acs-failed-download"
FAKE_FAIL_PACKAGE=1 ACS_ENV_FILE="$TEST_ROOT/etc/acs-failed-env.conf" bash "$KIT_DIR/deploy.sh" --root="$failed_install_root" \
  --project=rb-acs-failed-test --no-systemd >/dev/null 2>&1
assert_equal "다운로드 실패 종료 코드" "1" "$?"
assert_true "다운로드 실패 시 받던 파일을 지움" test ! -e "$failed_install_root/.download"
assert_equal "--mode 채널 기록" "develop" "$(bash -c '. "$1"; echo "$ACS_RELEASE_CHANNEL"' _ "$online_install_env")"
bash "$KIT_DIR/deploy.sh" "$TEST_ROOT/acs-v1.zip" --no-systemd >/dev/null 2>&1
assert_equal "위치 인자 ZIP은 --input 안내 후 거절" "2" "$?"

echo "▶ deploy.sh: docker 권한이 없으면 그룹에 추가하고 sg로 다시 실행해 재로그인 없이 설치"
group_bin_dir="$TEST_ROOT/fake-group-bin"
mkdir -p "$group_bin_dir"
cat > "$group_bin_dir/sudo" <<'FAKE_SUDO'
#!/bin/bash
echo "sudo $*" >> "$FAKE_LOG"
exit 0
FAKE_SUDO
cat > "$group_bin_dir/id" <<'FAKE_ID'
#!/bin/bash
echo "acs-user"
FAKE_ID
cat > "$group_bin_dir/sg" <<'FAKE_SG'
#!/bin/bash
echo "sg $1" >> "$FAKE_LOG"
exec bash -c "$3"
FAKE_SG
chmod +x "$group_bin_dir/sudo" "$group_bin_dir/id" "$group_bin_dir/sg"
touch "$FAKE_STATE_DIR/docker-needs-group"
: > "$FAKE_LOG"
PATH="$group_bin_dir:$PATH" ACS_ENV_FILE="$TEST_ROOT/etc/acs-group-env.conf" bash "$KIT_DIR/deploy.sh" \
  --input="$TEST_ROOT/acs-v1.zip" --root="$TEST_ROOT/rb-acs-group" --project=rb-acs-group-test --no-systemd >/dev/null 2>&1
assert_equal "그룹 추가 후 이어서 설치 종료 코드" "0" "$?"
assert_true "docker 그룹 추가" grep -q "sudo usermod -aG docker" "$FAKE_LOG"
assert_true "sg docker로 다시 실행" grep -q "sg docker" "$FAKE_LOG"
assert_true "다시 실행한 쪽이 설치 완료" test -f "$TEST_ROOT/rb-acs-group/deploy/installed.json"
rm -f "$FAKE_STATE_DIR/docker-needs-group"

echo "▶ 태그 없이 만든 간이 배포 버전(-dev.<시각>)은 같은 번호의 정식 버전보다 낮다"
assert_equal "간이 배포 뒤 정식 버전은 새 버전" "true" "$(python3 -I "$KIT_DIR/release.py" version-is-newer 1.0.5 v1.0.5-dev.202611041530)"
assert_equal "간이 배포 버전은 이전 정식 버전보다 높음" "true" "$(python3 -I "$KIT_DIR/release.py" version-is-newer 1.0.5-dev.202611041530 v1.0.4)"
assert_equal "정식 버전에서 같은 번호 간이 버전은 낮음" "false" "$(python3 -I "$KIT_DIR/release.py" version-is-newer 1.0.5-dev.1 v1.0.5)"

echo "▶ 예전 이름(acs-observer.sh·acs-update.sh·lib/release_tool.py)으로 설치한 현장도 키트만 받으면 계속 동작"
: > "$FAKE_LOG"
bash "$KIT_DIR/acs-observer.sh" --once >/dev/null 2>&1
assert_equal "옛 observer 경로 종료 코드" "0" "$?"
assert_true "옛 observer 경로도 heartbeat 기록" test -f "$ACS_ROOT/deploy/observer.json"
assert_equal "옛 release_tool 경로" "true" "$(python3 -I "$KIT_DIR/lib/release_tool.py" version-is-newer 1.0.1 0.1.2)"
assert_equal "옛 update 경로는 사용법 오류(2)로 새 update.sh에 넘김" "2" "$(bash "$KIT_DIR/acs-update.sh" >/dev/null 2>&1; echo $?)"

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "✅ 통과 ${TEST_COUNT}개"
else
  echo "❌ 실패 ${FAILURES}개 / ${TEST_COUNT}개"
  exit 1
fi
