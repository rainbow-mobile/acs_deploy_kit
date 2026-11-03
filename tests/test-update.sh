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
    *" mongodump "*) echo "mongo-backup"; exit 0 ;;
    *" pg_dump "*) echo "pg-backup"; exit 0 ;;
    *) exit 0 ;;
  esac
fi
case "${1:-}" in
  info) exit 0 ;;
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
if [[ "$request_url" == */latest.json ]] && [ -n "${FAKE_ONLINE_MANIFEST:-}" ]; then
  cp "$FAKE_ONLINE_MANIFEST" "$output_path"; exit 0
fi
if [[ "$request_url" == */acs-*-update.zip || "$request_url" == */acs-*-install.zip ]] && [ -n "${FAKE_ONLINE_PACKAGE:-}" ]; then
  cp "$FAKE_ONLINE_PACKAGE" "$output_path"; exit 0
fi
[ -f "$FAKE_STATE_DIR/executions.json" ] && { cat "$FAKE_STATE_DIR/executions.json"; exit 0; }
exit 7
EOF
chmod +x "$FAKE_BIN_DIR/docker" "$FAKE_BIN_DIR/curl"
export PATH="$FAKE_BIN_DIR:$PATH"

# ── 설치 설정 ──
export ACS_ENV_FILE="$TEST_ROOT/etc/acs-env.conf"
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
import hashlib, json, sys, zipfile
output_path, version, services_csv, image_tag = sys.argv[1:5]
smc_conf = sys.argv[5] if len(sys.argv) > 5 else "listen 13100;\n"
entries = {}
services = {}
for service_name in services_csv.split(","):
    path = f"services/{service_name}/{service_name}.amd64.bin"
    content = f"#!/bin/sh\necho {service_name} {version}\n".encode()
    entries[path] = content
    services[service_name] = {"version": version, "path": path, "sha256": hashlib.sha256(content).hexdigest()}
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
    "kind": "acs.release", "format_version": 1, "version": version, "created_at": "2026-10-30T00:00:00Z", "git_commit": "abc1234",
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
rm -f "$FAKE_STATE_DIR/unhealthy-task"

echo "▶ 필요한 이미지가 없으면 바꾸기 전에 멈춤"
echo "mongo:7" > "$FAKE_STATE_DIR/missing-image"
assert_equal "이미지 없음 종료 코드" "1" "$(run_update "$TEST_ROOT/acs-v4-task.zip")"
assert_true "이미지 없음 메시지" grep -q "mongo:7" "$ACS_ROOT/deploy/status.json"
assert_true "task bin은 v2 그대로" grep -q "task v2" "$ACS_ROOT/services/task/task.amd64.bin"
rm -f "$FAKE_STATE_DIR/missing-image"

echo "▶ observer: 성공 ZIP은 지우고, 대기 ZIP은 두고, 실패 ZIP은 failed/로"
cp "$TEST_ROOT/acs-v4-task.zip" "$ACS_ROOT/deploy/observe/acs-v4-task.zip"
bash "$KIT_DIR/observer.sh" --once >/dev/null 2>&1
assert_true "적용한 ZIP 삭제" test ! -e "$ACS_ROOT/deploy/observe/acs-v4-task.zip"
assert_true "task bin은 v4" grep -q "task v4" "$ACS_ROOT/services/task/task.amd64.bin"
assert_true "heartbeat 기록" test -f "$ACS_ROOT/deploy/observer.json"
echo '[{"state":"action_required"}]' > "$FAKE_STATE_DIR/executions.json"
make_release "$TEST_ROOT/acs-v5-task.zip" v5 task -
cp "$TEST_ROOT/acs-v5-task.zip" "$ACS_ROOT/deploy/observe/acs-v5-task.zip"
bash "$KIT_DIR/observer.sh" --once >/dev/null 2>&1
assert_true "대기 ZIP은 남김" test -f "$ACS_ROOT/deploy/observe/acs-v5-task.zip"
assert_equal "observer 대기 상태" "waiting" "$(json_value "$ACS_ROOT/deploy/status.json" state)"
touch "$ACS_ROOT/deploy/observe/acs-v5-task.zip.force"
bash "$KIT_DIR/observer.sh" --once >/dev/null 2>&1
assert_true "강제 표시가 있으면 적용" grep -q "task v5" "$ACS_ROOT/services/task/task.amd64.bin"
assert_true "강제 표시 삭제" test ! -e "$ACS_ROOT/deploy/observe/acs-v5-task.zip.force"
rm -f "$FAKE_STATE_DIR/executions.json"
cp "$TEST_ROOT/acs-v3-broken.zip" "$ACS_ROOT/deploy/observe/acs-v3-broken.zip"
bash "$KIT_DIR/observer.sh" --once >/dev/null 2>&1
assert_true "실패 ZIP은 failed/로" test -f "$ACS_ROOT/deploy/failed/acs-v3-broken.zip"
assert_true "실패 ZIP은 observe/에서 빠짐" test ! -e "$ACS_ROOT/deploy/observe/acs-v3-broken.zip"
assert_equal "status의 ZIP 이름은 원래 이름" "acs-v3-broken.zip" "$(json_value "$ACS_ROOT/deploy/status.json" package)"

echo "▶ 온라인 자동배포: 기본은 조회하지 않고, 명시적으로 켜면 새 버전만 검증 후 적용"
make_release "$TEST_ROOT/acs-v6-task-update.zip" 6.0.0 task -
export FAKE_ONLINE_PACKAGE="$TEST_ROOT/acs-v6-task-update.zip"
export FAKE_ONLINE_MANIFEST="$TEST_ROOT/latest.json"
online_sha="$(sha256sum "$FAKE_ONLINE_PACKAGE" | cut -d' ' -f1)"
cat > "$FAKE_ONLINE_MANIFEST" <<EOF
{"kind":"acs.online-release","format_version":1,"version":"6.0.0","update":{"path":"update/6.0.0/acs-v6-task-update.zip","sha256":"$online_sha"}}
EOF
: > "$FAKE_LOG"
bash "$KIT_DIR/observer.sh" --once >/dev/null 2>&1
assert_true "기본 설정에서는 latest.json을 조회하지 않음" bash -c "! grep -q 'latest.json' '$FAKE_LOG'"
assert_true "기본 설정에서는 온라인 버전을 적용하지 않음" grep -q "task v5" "$ACS_ROOT/services/task/task.amd64.bin"
assert_equal "자동배포가 꺼져 있어도 --online 수동 적용" "0" "$(run_update --online)"
assert_true "수동 온라인 새 버전 적용" grep -q "task 6.0.0" "$ACS_ROOT/services/task/task.amd64.bin"

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
assert_equal "--mode 채널 기록" "develop" "$(bash -c '. "$1"; echo "$ACS_RELEASE_CHANNEL"' _ "$online_install_env")"
bash "$KIT_DIR/deploy.sh" "$TEST_ROOT/acs-v1.zip" --no-systemd >/dev/null 2>&1
assert_equal "위치 인자 ZIP은 --input 안내 후 거절" "2" "$?"

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "✅ 통과 ${TEST_COUNT}개"
else
  echo "❌ 실패 ${FAILURES}개 / ${TEST_COUNT}개"
  exit 1
fi
