"""ACS 릴리즈 ZIP 처리 보조 도구입니다. update.sh·observer.sh가 부릅니다.

오프라인 현장에는 jq·unzip이 없을 수 있어 Ubuntu 기본 python3의 표준 라이브러리만 씁니다.
항상 `python3 -I`(현재 디렉터리·사용자 site 무시)로 실행합니다.

명령:
    extract <zip> <staging>                      안전하게 압축 해제(경로 탈출 차단)
    validate <staging> <arch>                    매니페스트 종류·형식·arch와 모든 파일 sha256 확인
    get <staging> <key>                          매니페스트 값(version, git_commit, services, images.archive, images.tag)
    count-active                                 stdin의 Task 실행 목록에서 끝나지 않은 실행 수
    write-status <file> <state> <stage> <message> <package> <version>
    write-heartbeat <file> <interval_sec>
    record <installed.json> <staging> <images_tag> <result> <message>
    installed-get <installed.json> <key>         설치 정보 값(version, images_tag)
    make-site-env <zip> <site.env> <frs_url> <moms_url>  ZIP의 site.env.example로 site.env를 만들고 DB 비밀번호를 무작위로 채움
    snapshot <staging> <acs_root> <installed.json> <archives_dir> <arch>  바뀔 서비스의 현재 bin·설정을 되돌리기용 릴리즈 ZIP으로 보관
    online-summary <check_dir> <installed.json> <online.json> <channel> <base_url> <auto_update> <auto_update_source>
                                                 observer가 받은 latest.json·서비스별 version.json으로 버전 탭 최신 버전 표시(online.json)
    online-describe <online.json>                online.json을 observer 로그 한 줄로 요약
    online-next <online.json> <installed.json>   자동 업데이트할 대상(total 또는 서비스 이름, 없으면 빈 줄)
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import signal
import socket
import sys
import tempfile
import time
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from urllib.request import Request, urlopen

# 릴리즈 매니페스트 종류와 지원 형식 버전입니다(rb_acs scripts/deployment/build_release.py).
RELEASE_KIND = "acs.release"
SUPPORTED_FORMAT_VERSION = 1
# Task 실행이 끝난 상태입니다(rb_acs task execution_repository.TERMINAL_STATES). 그 밖의 상태는 실행 중으로 봅니다.
TERMINAL_EXECUTION_STATES = {"completed", "stopped", "cancelled", "restarted", "idle"}
# installed.json에 남기는 적용 이력 수입니다.
HISTORY_LIMIT = 20
# 업데이트 실행 기록(deploy/runs/<run_id>.json)을 남길 최근 개수입니다.
RUN_LIMIT = 30
# 업데이트 요청 출처입니다. Debugger 버전 탭이 이름으로 보여 줍니다.
RUN_SOURCES = ("ui-upload", "ui-rollback", "ui-online", "online-auto", "online-manual", "offline-file", "cli", "install")
# 버전 비교에 쓰는 세 자리 숫자 버전 형식입니다(v 접두사 허용). 태그 없이 만든 간이 배포는 `1.0.5-dev.202611041530`처럼
# 뒤에 붙은 이름이 있고, 같은 번호의 정식 버전보다 낮게 봅니다(나중에 나온 1.0.5 정식 버전을 새 버전으로 알아봄).
VERSION_PATTERN = re.compile(r"^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?$")
# 이 키트 observer가 처리할 수 있는 기능입니다. heartbeat에 적어 화면·Common이 예전 키트와 구분합니다(online: 버전 탭 온라인 요청).
OBSERVER_FEATURES = ("online",)
# online.json에 남길 연결 오류 내용 길이입니다.
ONLINE_ERROR_LIMIT = 300
# 업데이트 전 버전 보관본 기본 개수입니다. Common이 활성 Scenario 정책 값을 deploy/settings.json에 적으면 그 값을 씁니다.
DEFAULT_ARCHIVE_KEEP_COUNT = 3


def fail(message: str) -> None:
    """오류를 표준 오류로 알리고 종료 코드 1로 끝냅니다.

    Args:
        message (str): 오류 메시지입니다.
    """
    print(message, file=sys.stderr)
    sys.exit(1)


def write_json_atomic(file_path: Path, value: dict) -> None:
    """같은 디렉터리 임시 파일에 쓴 뒤 이름을 바꿔, 읽는 쪽이 반쯤 쓴 JSON을 보지 않게 합니다.

    Args:
        file_path (Path): 쓸 파일입니다.
        value (dict): 쓸 값입니다.
    """
    file_path.parent.mkdir(parents=True, exist_ok=True)
    file_descriptor, temporary_name = tempfile.mkstemp(prefix=f".{file_path.name}.", dir=file_path.parent)
    with os.fdopen(file_descriptor, "w", encoding="utf-8") as temporary_file:
        json.dump(value, temporary_file, ensure_ascii=False, indent=2)
    os.chmod(temporary_name, 0o644)
    os.replace(temporary_name, file_path)


def read_json(file_path: Path) -> dict:
    """JSON 파일을 읽습니다. 없거나 깨졌으면 빈 dict입니다.

    Args:
        file_path (Path): 읽을 파일입니다.

    Returns:
        dict: 읽은 값입니다.
    """
    try:
        loaded_value = json.loads(file_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return loaded_value if isinstance(loaded_value, dict) else {}


def file_sha256(file_path: Path) -> str:
    """파일 sha256을 나눠 읽으며 계산합니다.

    Args:
        file_path (Path): 계산할 파일입니다.

    Returns:
        str: 16진수 sha256입니다.
    """
    file_hash = hashlib.sha256()
    with file_path.open("rb") as hashed_file:
        while file_chunk := hashed_file.read(4 * 1024 * 1024):
            file_hash.update(file_chunk)
    return file_hash.hexdigest()


def json_get(file_name: str, key_path: str) -> None:
    """JSON 문서의 점 구분 경로 값을 출력합니다.

    Args:
        file_name (str): JSON 파일 경로입니다.
        key_path (str): 예: update.path 형태의 키 경로입니다.
    """
    value: object = read_json(Path(file_name))
    for key_name in key_path.split("."):
        value = value.get(key_name) if isinstance(value, dict) else None
    print("" if value is None else value)


def is_newer_version(candidate: str, installed: str) -> bool:
    """candidate가 설치 버전보다 높은 세 자리 숫자 버전인지 봅니다. 설치 버전이 없으면(새 서비스) 높은 것으로 봅니다.

    Args:
        candidate (str): 온라인 후보 버전입니다.
        installed (str): 현재 설치 버전입니다.

    Returns:
        bool: 더 높으면 True입니다. 후보가 숫자 버전이 아니거나 설치 버전이 숫자 버전이 아니면(시험 빌드) False입니다.
    """
    candidate_match = VERSION_PATTERN.fullmatch(candidate or "")
    if not candidate_match:
        return False
    if not installed:
        return True
    installed_match = VERSION_PATTERN.fullmatch(installed)
    if not installed_match:
        return False
    # (숫자 세 자리, 정식이면 1·뒤 이름이 있으면 0, 뒤 이름) 순서로 비교합니다.
    candidate_key = (
        tuple(int(number or 0) for number in candidate_match.groups()[:3]),
        0 if candidate_match.group(4) else 1, candidate_match.group(4) or "",
    )
    installed_key = (
        tuple(int(number or 0) for number in installed_match.groups()[:3]),
        0 if installed_match.group(4) else 1, installed_match.group(4) or "",
    )
    return candidate_key > installed_key


def version_is_newer(candidate: str, installed: str) -> None:
    """candidate가 설치 버전보다 높은 세 자리 숫자 버전인지 출력합니다.

    Args:
        candidate (str): 온라인 후보 버전입니다.
        installed (str): 현재 설치 버전입니다.
    """
    print("true" if installed and is_newer_version(candidate, installed) else "false")


# 다운로드 경과를 출력하는 최소 간격(초)입니다. 터미널과 observer 로그 모두 줄 단위로 남깁니다.
DOWNLOAD_PROGRESS_INTERVAL_SEC = 3


def format_duration(seconds: float) -> str:
    """초를 `2m05s`처럼 읽기 쉽게 바꿉니다.

    Args:
        seconds (float): 초입니다.

    Returns:
        str: 표시 문자열입니다.
    """
    whole_seconds = int(seconds)
    return f"{whole_seconds // 60}m{whole_seconds % 60:02d}s" if whole_seconds >= 60 else f"{whole_seconds}s"


def download(url: str, output_name: str, timeout_text: str, progress_text: str = "0") -> None:
    """HTTP(S) 파일을 내려받습니다. progress면 받은 양·속도·경과·남은 시간을 몇 초마다 한 줄씩 출력합니다.

    Args:
        url (str): 다운로드 URL입니다.
        output_name (str): 저장할 파일 경로입니다.
        timeout_text (str): 요청 제한 시간(초)입니다.
        progress_text (str): "1"이면 경과를 출력합니다.
    """
    request = Request(url, headers={"User-Agent": "RB-ACS-Deploy/1", "Cache-Control": "no-cache"})
    output_path = Path(output_name)
    partial_path = output_path.with_name(f".{output_path.name}.part")
    show_progress = progress_text == "1"
    file_label = url.rsplit("/", 1)[-1]
    started_at = time.monotonic()
    # 종료 신호(SIGTERM)도 예외로 바꿔 아래에서 받던 파일을 지우게 합니다.
    signal.signal(signal.SIGTERM, lambda signal_number, frame: sys.exit(143))
    try:
        with urlopen(request, timeout=int(timeout_text)) as response, partial_path.open("wb") as output_file:
            total_bytes = int(response.headers.get("Content-Length") or 0)
            received_bytes = 0
            reported_at = started_at
            while chunk := response.read(1024 * 1024):
                output_file.write(chunk)
                received_bytes += len(chunk)
                now = time.monotonic()
                if show_progress and now - reported_at >= DOWNLOAD_PROGRESS_INTERVAL_SEC:
                    reported_at = now
                    elapsed_seconds = now - started_at
                    speed = received_bytes / elapsed_seconds if elapsed_seconds > 0 else 0
                    received_megabytes = received_bytes / 1024 / 1024
                    if total_bytes:
                        remaining_seconds = (total_bytes - received_bytes) / speed if speed > 0 else 0
                        print(
                            f"   📥 {file_label} {received_bytes * 100 // total_bytes:3d}% "
                            f"{received_megabytes:.0f}/{total_bytes / 1024 / 1024:.0f}MB · {speed / 1024 / 1024:.1f}MB/s · "
                            f"경과 {format_duration(elapsed_seconds)} · 남은 시간 약 {format_duration(remaining_seconds)}",
                            flush=True,
                        )
                    else:
                        print(
                            f"   📥 {file_label} {received_megabytes:.0f}MB · {speed / 1024 / 1024:.1f}MB/s · 경과 {format_duration(elapsed_seconds)}",
                            flush=True,
                        )
        os.replace(partial_path, output_path)
        if show_progress:
            elapsed_seconds = time.monotonic() - started_at
            print(
                f"   📥 {file_label} 완료 {received_bytes / 1024 / 1024:.0f}MB · 걸린 시간 {format_duration(elapsed_seconds)}",
                flush=True,
            )
    except (OSError, ValueError) as error:
        partial_path.unlink(missing_ok=True)
        fail(f"다운로드 실패: {error}")
    except BaseException:
        # Ctrl+C·종료 신호로 멈추면 받던 파일을 남기지 않습니다.
        partial_path.unlink(missing_ok=True)
        raise


def extract(archive_name: str, staging_name: str) -> None:
    """ZIP을 staging 디렉터리에 풉니다. 절대 경로·`..`로 staging 밖에 쓰려는 항목이 있으면 거절합니다.

    Args:
        archive_name (str): ZIP 경로입니다.
        staging_name (str): 풀 디렉터리입니다.
    """
    staging_directory = Path(staging_name).resolve()
    staging_directory.mkdir(parents=True, exist_ok=True)
    if not zipfile.is_zipfile(archive_name):
        fail("ZIP 파일이 아닙니다.")
    with zipfile.ZipFile(archive_name) as release_archive:
        for member in release_archive.infolist():
            target_path = (staging_directory / member.filename).resolve()
            if staging_directory not in target_path.parents and target_path != staging_directory:
                fail(f"ZIP에 설치 디렉터리 밖을 가리키는 경로가 있습니다: {member.filename}")
        release_archive.extractall(staging_directory)


def load_manifest(staging_directory: Path) -> dict:
    """staging의 version.json을 읽습니다.

    Args:
        staging_directory (Path): 푼 디렉터리입니다.

    Returns:
        dict: 매니페스트입니다.
    """
    manifest = read_json(staging_directory / "version.json")
    if not manifest:
        fail("version.json이 없거나 읽을 수 없습니다. make backend.deploy로 만든 릴리즈 ZIP인지 확인하세요.")
    return manifest


def validate(staging_name: str, architecture: str) -> None:
    """매니페스트 종류·형식 버전·arch를 확인하고 모든 서비스 bin·runtime 파일·이미지 tar의 sha256을 맞춰 봅니다.

    Args:
        staging_name (str): 푼 디렉터리입니다.
        architecture (str): 이 PC arch입니다(amd64).
    """
    staging_directory = Path(staging_name)
    manifest = load_manifest(staging_directory)
    if manifest.get("kind") != RELEASE_KIND:
        fail(f"ACS 릴리즈 ZIP이 아닙니다(kind={manifest.get('kind')}).")
    if manifest.get("format_version") != SUPPORTED_FORMAT_VERSION:
        fail(f"이 배포 키트가 모르는 릴리즈 형식 버전입니다: {manifest.get('format_version')}. 배포 키트를 갱신하세요.")
    if manifest.get("arch") != architecture:
        fail(f"이 PC({architecture})와 arch가 다릅니다: {manifest.get('arch')}")
    if not manifest.get("version"):
        fail("version.json에 version이 없습니다.")
    expected_files = {}
    for service_name, service_entry in (manifest.get("services") or {}).items():
        expected_files[service_entry["path"]] = (service_entry["sha256"], f"서비스 {service_name}")
    runtime_path = (manifest.get("runtime") or {}).get("path") or "runtime"
    for relative_path, runtime_sha256 in ((manifest.get("runtime") or {}).get("files") or {}).items():
        expected_files[f"{runtime_path}/{relative_path}"] = (runtime_sha256, "설정 파일")
    images = manifest.get("images") or {}
    if images.get("archive"):
        expected_files[images["archive"]] = (images.get("sha256"), "이미지")
    for relative_path, (expected_sha256, file_kind) in expected_files.items():
        file_path = staging_directory / relative_path
        if not file_path.is_file():
            fail(f"{file_kind} 파일이 ZIP에 없습니다: {relative_path}")
        if file_sha256(file_path) != expected_sha256:
            fail(f"{file_kind} 파일 sha256이 다릅니다(전송 중 손상 의심): {relative_path}")


def get(staging_name: str, key: str) -> None:
    """매니페스트 값을 출력합니다. services는 쉼표로 이은 서비스 이름입니다.

    Args:
        staging_name (str): 푼 디렉터리입니다.
        key (str): 읽을 값 이름입니다.
    """
    manifest = load_manifest(Path(staging_name))
    if key == "services":
        print(",".join(sorted(manifest.get("services") or {})))
    elif key.startswith("images."):
        print((manifest.get("images") or {}).get(key.removeprefix("images.")) or "")
    else:
        print(manifest.get(key) or "")


def count_active() -> None:
    """표준 입력의 Task 실행 목록(`GET /task/execution/executions`)에서 끝나지 않은 실행 수를 출력합니다."""
    try:
        executions = json.load(sys.stdin)
    except ValueError:
        fail("Task 실행 목록을 읽지 못했습니다.")
    print(sum(1 for execution in executions if isinstance(execution, dict) and execution.get("state") not in TERMINAL_EXECUTION_STATES))


def write_status(status_name: str, state: str, stage: str, message: str, package: str, version: str) -> None:
    """업데이트 진행 상태(status.json)를 씁니다. Common deploy feature가 읽어 화면에 보냅니다.

    Args:
        status_name (str): status.json 경로입니다.
        state (str): queued·waiting·running·success·failed입니다.
        stage (str): 진행 단계입니다.
        message (str): 화면에 보일 메시지입니다.
        package (str): ZIP 이름입니다.
        version (str): 릴리즈 버전입니다.
    """
    write_json_atomic(Path(status_name), {
        "state": state, "stage": stage, "message": message, "package": package, "version": version,
        "updated_at": int(time.time() * 1000),
    })


def utc_now_text() -> str:
    """현재 UTC 시각 문자열입니다.

    Returns:
        str: 예) 2026-11-03T06:10:00Z
    """
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def run_start(runs_name: str, run_id: str, source: str, package: str) -> None:
    """업데이트 실행 기록을 만듭니다. 같은 run_id 기록이 있으면(Task 대기 뒤 다시 시도) 그대로 이어 씁니다.

    Args:
        runs_name (str): deploy/runs 디렉터리입니다.
        run_id (str): 실행 ID입니다.
        source (str): 요청 출처(RUN_SOURCES)입니다.
        package (str): ZIP 이름입니다.
    """
    if source not in RUN_SOURCES:
        fail(f"알 수 없는 업데이트 출처입니다: {source}")
    runs_directory = Path(runs_name)
    runs_directory.mkdir(parents=True, exist_ok=True)
    run_path = runs_directory / f"{run_id}.json"
    if not run_path.is_file():
        write_json_atomic(run_path, {
            "run_id": run_id, "source": source, "package": package, "version": None, "result": "running",
            "started_at": utc_now_text(), "ended_at": None, "stopped_stage": None, "stages": [], "notes": [],
        })
    # 오래된 실행 기록은 RUN_LIMIT개만 남깁니다.
    run_paths = sorted(runs_directory.glob("*.json"), key=lambda path: path.stat().st_mtime)
    for old_run_path in run_paths[:-RUN_LIMIT]:
        old_run_path.unlink(missing_ok=True)


def run_stage(run_name: str, state: str, stage: str, message: str, version: str) -> None:
    """실행 기록에 단계 진행을 남깁니다. 단계가 바뀌면 앞 단계를 끝내고, 끝 상태(success·failed)면 실행을 끝냅니다.

    Args:
        run_name (str): 실행 기록 파일입니다. 없으면 아무것도 하지 않습니다.
        state (str): queued·waiting·running·success·failed입니다.
        stage (str): 진행 단계입니다.
        message (str): 단계 메시지입니다.
        version (str): 릴리즈 버전입니다(알면).
    """
    run_path = Path(run_name)
    if not run_path.is_file():
        return
    run_record = read_json(run_path)
    now_text = utc_now_text()
    stages = run_record.setdefault("stages", [])
    last_stage = stages[-1] if stages else None
    if last_stage and last_stage["stage"] == stage:
        last_stage.update({"state": state, "message": message})
    else:
        if last_stage and not last_stage.get("ended_at"):
            last_stage["ended_at"] = now_text
            if last_stage["state"] in ("running", "queued", "waiting"):
                last_stage["state"] = "done"
        stages.append({"stage": stage, "state": state, "message": message, "started_at": now_text, "ended_at": None})
    if version:
        run_record["version"] = version
    if state in ("success", "failed"):
        stages[-1]["ended_at"] = now_text
        run_record.update({"result": state, "ended_at": now_text})
        if state == "failed":
            # 되돌리기(rollback) 단계에서 끝났으면 실제로 실패한 그 앞 단계를 멈춘 단계로 남깁니다.
            failed_stages = [stage_record["stage"] for stage_record in stages if stage_record["stage"] != "rollback"]
            run_record["stopped_stage"] = failed_stages[-1] if stage == "rollback" and failed_stages else stage
    elif state == "waiting":
        run_record["result"] = "waiting"
    else:
        run_record["result"] = "running"
    write_json_atomic(run_path, run_record)


def run_note(run_name: str, level: str, stage: str, message: str) -> None:
    """실행 기록에 경고·에러를 남깁니다.

    Args:
        run_name (str): 실행 기록 파일입니다. 없으면 아무것도 하지 않습니다.
        level (str): warning 또는 error입니다.
        stage (str): 그때 단계입니다.
        message (str): 내용입니다.
    """
    run_path = Path(run_name)
    if not run_path.is_file():
        return
    run_record = read_json(run_path)
    run_record.setdefault("notes", []).append({"level": level, "stage": stage, "message": message, "at": utc_now_text()})
    write_json_atomic(run_path, run_record)


def prune_archives(archives_name: str, settings_name: str) -> None:
    """업데이트 전 버전 보관본을 정해진 개수만 남기고 오래된 것부터 지웁니다. 지운 파일 이름을 출력합니다.

    개수는 deploy/settings.json의 archive_keep_count(활성 Scenario 정책, Common이 씀)이고 없으면 DEFAULT_ARCHIVE_KEEP_COUNT입니다.

    Args:
        archives_name (str): deploy/archives 디렉터리입니다.
        settings_name (str): deploy/settings.json 경로입니다.
    """
    keep_count = DEFAULT_ARCHIVE_KEEP_COUNT
    settings_path = Path(settings_name)
    if settings_path.is_file():
        try:
            keep_count = max(1, int(read_json(settings_path).get("archive_keep_count") or DEFAULT_ARCHIVE_KEEP_COUNT))
        except (TypeError, ValueError):
            keep_count = DEFAULT_ARCHIVE_KEEP_COUNT
    archive_paths = sorted(Path(archives_name).glob("acs-rollback-*.zip"), key=lambda path: path.stat().st_mtime)
    for old_archive_path in archive_paths[:-keep_count]:
        old_archive_path.unlink(missing_ok=True)
        print(old_archive_path.name)


def write_heartbeat(heartbeat_name: str, interval_seconds: str) -> None:
    """observer heartbeat(observer.json)를 씁니다. 화면은 경과 시간으로 observer 동작 여부를 판단합니다.

    Args:
        heartbeat_name (str): observer.json 경로입니다.
        interval_seconds (str): observer 확인 주기(초)입니다.
    """
    write_json_atomic(Path(heartbeat_name), {
        "updated_at": int(time.time() * 1000), "interval_sec": int(interval_seconds), "host": socket.gethostname(), "pid": os.getppid(),
        "features": list(OBSERVER_FEATURES),
    })


def is_total_bundle(manifest: dict, installed_services: dict) -> bool:
    """이 릴리즈를 적용하면 설치 통합 버전이 매니페스트 version이 되는지 판단합니다.

    서비스·간이 ZIP도 매니페스트 version에 빌드 때 최신 통합 버전이 들어 있습니다. 그 값을 설치 통합 버전으로 적으면 나머지
    서비스가 옛 버전인데도 통합 버전이 최신으로 보여 통합 업데이트가 막힙니다. 그래서 `bundle`이 `total`일 때만 통합 버전으로 봅니다.
    `bundle`이 없는 예전 ZIP은 설치된 서비스를 모두 담았을 때만 통합으로 봅니다(최초 설치는 설치 서비스가 없어 통합).

    Args:
        manifest (dict): 적용할 릴리즈 매니페스트입니다.
        installed_services (dict): 적용 전 installed.json의 서비스별 정보입니다.

    Returns:
        bool: 통합 묶음이면 True입니다.
    """
    bundle = manifest.get("bundle")
    if bundle:
        return bundle == "total"
    return set(installed_services) <= set(manifest.get("services") or {})


def record(
    installed_name: str, staging_name: str, images_tag: str, result: str, message: str, run_id: str = "", source: str = "",
) -> None:
    """적용 결과를 installed.json에 남깁니다. 성공이면 서비스별 버전과 이미지 태그를 바꾸고, 실패면 이력만 더합니다.

    설치 통합 버전(`version`·`git_commit`)은 통합 묶음을 적용했을 때만 바꿉니다(`is_total_bundle`).

    Args:
        installed_name (str): installed.json 경로입니다.
        staging_name (str): 푼 디렉터리입니다.
        images_tag (str): 적용 후 Gateway·Zenoh router 이미지 태그입니다.
        result (str): success 또는 failed입니다.
        message (str): 결과 메시지입니다.
        run_id (str): 실행 기록 ID입니다(deploy/runs/<run_id>.json).
        source (str): 요청 출처입니다.
    """
    installed_path = Path(installed_name)
    installed = read_json(installed_path)
    manifest = load_manifest(Path(staging_name))
    applied_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if result == "success":
        installed_services = installed.get("services") or {}
        total_bundle = is_total_bundle(manifest, installed_services)
        for service_name, service_entry in (manifest.get("services") or {}).items():
            # 브랜치(온라인 채널)는 서비스마다 다를 수 있습니다(예: develop 서비스 ZIP을 main 현장에 적용). 예전 ZIP은 없습니다.
            installed_services[service_name] = {
                "version": service_entry["version"], "sha256": service_entry["sha256"], "installed_at": applied_at,
                "branch": service_entry.get("branch") or manifest.get("branch"),
            }
        if total_bundle:
            installed.update({"version": manifest["version"], "git_commit": manifest.get("git_commit")})
        installed.update({
            "installed_at": applied_at, "branch": manifest.get("branch") or installed.get("branch"),
            "images_tag": images_tag, "services": installed_services,
        })
    history = installed.get("history") or []
    history.append({
        "version": manifest.get("version"), "result": result, "at": applied_at, "message": message,
        "services": sorted(manifest.get("services") or {}), "run_id": run_id or None, "source": source or None,
    })
    installed["history"] = history[-HISTORY_LIMIT:]
    write_json_atomic(installed_path, installed)


def installed_get(installed_name: str, key: str) -> None:
    """installed.json 값을 출력합니다. 없으면 빈 줄입니다.

    Args:
        installed_name (str): installed.json 경로입니다.
        key (str): 읽을 값 이름입니다.
    """
    print(read_json(Path(installed_name)).get(key) or "")


def make_site_env(archive_name: str, site_env_name: str, frs_url: str, moms_url: str) -> None:
    """릴리즈 ZIP의 runtime/site.env.example로 현장 site.env를 만듭니다.

    PostgreSQL·MongoDB의 관리자·운영·DDL 비밀번호를 각각 URI에 안전한 무작위 값으로 만들고, FRS·MOMS 주소는 받은 값이 있으면 넣습니다.
    설치 후 DB 비밀번호를 바꾸면 기존 DB에 접속하지 못하므로 이 파일은 처음 한 번만 만듭니다.

    Args:
        archive_name (str): 릴리즈 ZIP 경로입니다.
        site_env_name (str): 만들 site.env 경로입니다.
        frs_url (str): FRS REST 주소입니다. 비면 예시 값을 둡니다.
        moms_url (str): SMC MOMS 주소입니다. 비면 예시 값을 둡니다.
    """
    with zipfile.ZipFile(archive_name) as release_archive:
        example_lines = release_archive.read("runtime/site.env.example").decode("utf-8").splitlines()
    replacements = {
        "POSTGRES_PASSWORD": secrets.token_urlsafe(24),
        "MONGO_INITDB_ROOT_PASSWORD": secrets.token_urlsafe(24),
        "ACS_RUNTIME_PASSWORD_ENCODED": secrets.token_urlsafe(24),
        "ACS_SCHEMA_PASSWORD_ENCODED": secrets.token_urlsafe(24),
        "ACS_MONGO_RUNTIME_PASSWORD_ENCODED": secrets.token_urlsafe(24),
        "ACS_MONGO_SCHEMA_PASSWORD_ENCODED": secrets.token_urlsafe(24),
    }
    if frs_url:
        replacements["FRS_API_BASE_URL"] = frs_url
    if moms_url:
        replacements["SMC_MOMS_URL"] = moms_url
    site_lines = []
    for example_line in example_lines:
        key_name = example_line.split("=", 1)[0].strip()
        if not example_line.lstrip().startswith("#") and "=" in example_line and key_name in replacements:
            site_lines.append(f"{key_name}={replacements[key_name]}")
        else:
            site_lines.append(example_line)
    site_env_path = Path(site_env_name)
    site_env_path.parent.mkdir(parents=True, exist_ok=True)
    site_env_path.write_text("\n".join(site_lines) + "\n", encoding="utf-8")
    os.chmod(site_env_path, 0o600)


# 보관본 .env에서 뺄 이미지 태그 줄입니다. 보관본을 적용할 때 엔진이 설치된 이미지 태그를 다시 붙입니다.
IMAGE_TAG_LINE_PREFIXES = ("ACS_IMAGE_TAG=", "# Gateway·Zenoh router 이미지 태그")


def snapshot(staging_name: str, acs_root_name: str, installed_name: str, archives_name: str, architecture: str) -> None:
    """업데이트로 바뀔 서비스의 현재 bin과 현재 설정을 되돌리기용 릴리즈 ZIP으로 보관하고 그 경로를 출력합니다.

    보관본은 업데이트 ZIP과 같은 형식(acs.release)이라 다시 적용하면 그대로 되돌아갑니다. 바뀔 서비스만 담고,
    매니페스트에 서비스별 이전 버전과 어느 버전 적용 전인지(snapshot.replaced_by)를 적습니다.
    바뀔 서비스가 아직 설치되지 않았으면(최초 설치) 아무것도 만들지 않고 빈 줄을 출력합니다.

    Args:
        staging_name (str): 적용할 릴리즈를 푼 디렉터리입니다.
        acs_root_name (str): 설치 디렉터리입니다.
        installed_name (str): installed.json 경로입니다.
        archives_name (str): 보관본을 둘 디렉터리입니다.
        architecture (str): 이 PC arch입니다.
    """
    staging_directory = Path(staging_name)
    acs_root = Path(acs_root_name)
    new_manifest = load_manifest(staging_directory)
    installed = read_json(Path(installed_name))
    previous_version = str(installed.get("version") or "unknown")
    installed_services = installed.get("services") or {}
    service_files = {}
    for service_name in sorted(new_manifest.get("services") or {}):
        bin_relative_path = f"services/{service_name}/{service_name}.{architecture}.bin"
        if (acs_root / bin_relative_path).is_file():
            service_files[service_name] = bin_relative_path
    if not service_files:
        print("")
        return

    runtime_path = (new_manifest.get("runtime") or {}).get("path") or "runtime"
    runtime_contents = {}
    for relative_path in ((new_manifest.get("runtime") or {}).get("files") or {}):
        installed_path = acs_root / relative_path
        if not installed_path.is_file():
            continue
        file_bytes = installed_path.read_bytes()
        if relative_path == ".env":
            file_bytes = "".join(
                env_line for env_line in file_bytes.decode("utf-8").splitlines(keepends=True)
                if not env_line.startswith(IMAGE_TAG_LINE_PREFIXES)
            ).encode("utf-8")
        runtime_contents[relative_path] = file_bytes

    taken_at = datetime.now(timezone.utc)
    snapshot_manifest = {
        "kind": RELEASE_KIND,
        "format_version": SUPPORTED_FORMAT_VERSION,
        "version": previous_version,
        # 통합 묶음 적용 전 보관본을 되돌리면 설치 통합 버전도 이전 값으로, 서비스 ZIP 적용 전 보관본이면 그대로 둡니다.
        "bundle": "total" if is_total_bundle(new_manifest, installed_services) else "service",
        "branch": installed.get("branch"),
        "created_at": taken_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "git_commit": installed.get("git_commit"),
        "arch": architecture,
        "services": {
            service_name: {
                "version": (installed_services.get(service_name) or {}).get("version") or previous_version,
                # 되돌리면 그 서비스의 예전 브랜치로 기록되게 둡니다.
                "branch": (installed_services.get(service_name) or {}).get("branch"),
                "path": bin_relative_path,
                "sha256": file_sha256(acs_root / bin_relative_path),
            }
            for service_name, bin_relative_path in service_files.items()
        },
        "runtime": {
            "path": runtime_path,
            "files": {relative_path: hashlib.sha256(file_bytes).hexdigest() for relative_path, file_bytes in runtime_contents.items()},
        },
        "images": {"tag": None, "names": [], "archive": None, "sha256": None},
        "snapshot": {"replaced_by": new_manifest.get("version"), "taken_at": taken_at.strftime("%Y-%m-%dT%H:%M:%SZ")},
    }
    archives_directory = Path(archives_name)
    archives_directory.mkdir(parents=True, exist_ok=True)

    def safe_label(version_label: str) -> str:
        """파일 이름에 쓸 수 있게 버전 이름의 특수 문자를 바꿉니다.

        Args:
            version_label (str): 버전 이름입니다.

        Returns:
            str: 영문·숫자·.-_만 남긴 이름입니다.
        """
        return re.sub(r"[^A-Za-z0-9._-]", "_", version_label)

    archive_name = f"acs-rollback-{safe_label(previous_version)}-before-{safe_label(str(new_manifest.get('version')))}-{taken_at.astimezone().strftime('%Y%m%d-%H%M%S')}.zip"
    archive_path = archives_directory / archive_name
    # 쓰는 동안은 .zip이 아닌 이름이라 화면 목록과 observer에 보이지 않습니다.
    partial_path = archives_directory / f".{archive_name}.part"
    with zipfile.ZipFile(partial_path, "w", compression=zipfile.ZIP_STORED, allowZip64=True) as snapshot_archive:
        snapshot_archive.writestr("version.json", json.dumps(snapshot_manifest, ensure_ascii=False, indent=2) + "\n")
        for bin_relative_path in service_files.values():
            snapshot_archive.write(acs_root / bin_relative_path, bin_relative_path)
        for relative_path, file_bytes in runtime_contents.items():
            snapshot_archive.writestr(f"{runtime_path}/{relative_path}", file_bytes)
    os.chmod(partial_path, 0o644)
    os.replace(partial_path, archive_path)
    print(archive_path)


def online_summary(
    check_name: str, installed_name: str, online_name: str, channel: str, base_url: str, auto_update: str, auto_update_source: str,
) -> None:
    """observer가 받은 매니페스트로 버전 탭이 보여 줄 최신 버전(online.json)을 씁니다.

    check_dir에는 `latest.json`(통합)과 `services/<서비스>.json`(서비스별 version.json)이 받은 것만 있고, 받지 못한 이유는 `error`에
    있습니다. 하나도 받지 못하면 인터넷에 연결되지 않은 것(reachable=false)으로 남깁니다. 새 버전 여부(newer)는 지금 설치 버전과 비교합니다.

    Args:
        check_name (str): 받은 매니페스트 디렉터리입니다.
        installed_name (str): installed.json 경로입니다.
        online_name (str): 쓸 online.json 경로입니다.
        channel (str): 온라인 채널(main·develop)입니다.
        base_url (str): 채널 주소입니다.
        auto_update (str): 지금 적용 중인 자동 업데이트 설정("1"이면 켜짐)입니다.
        auto_update_source (str): 자동 업데이트 설정 출처(ui: 버전 탭, site-config: 설치 설정 파일)입니다.
    """
    check_directory = Path(check_name)
    installed = read_json(Path(installed_name))
    installed_services = installed.get("services") or {}
    total = None
    latest_manifest = read_json(check_directory / "latest.json")
    if latest_manifest.get("kind") == "acs.online-release" and latest_manifest.get("version"):
        update_entry = latest_manifest.get("update") or {}
        total = {
            "version": latest_manifest["version"], "installed": installed.get("version"),
            "newer": is_newer_version(latest_manifest["version"], installed.get("version") or "0.0.0"),
            "path": update_entry.get("path"), "sha256": update_entry.get("sha256"),
        }
    services = {}
    services_directory = check_directory / "services"
    for service_path in sorted(services_directory.glob("*.json")) if services_directory.is_dir() else []:
        service_document = read_json(service_path)
        service_version = str(service_document.get("new_version") or "")
        if not VERSION_PATTERN.fullmatch(service_version):
            continue
        service_name = service_path.stem
        installed_version = (installed_services.get(service_name) or {}).get("version") or ""
        services[service_name] = {
            "version": service_version, "installed": installed_version or None,
            "newer": is_newer_version(service_version, installed_version),
            # 서비스 ZIP은 <채널>/<서비스>/<버전>.zip입니다. sha256은 새로 배포한 서비스부터 version.json에 있습니다.
            "path": service_document.get("path") or f"{service_name}/{service_version}.zip",
            "sha256": service_document.get("sha256"),
        }
    reachable = total is not None or bool(services) or (check_directory / "latest.json").is_file()
    try:
        error_text = (check_directory / "error").read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        error_text = ""
    # 받지 못한 이유가 모두 404면 인터넷은 되는데 그 채널에 배포한 적이 없는 것입니다(현장 --mode와 배포 브랜치가 다름).
    error_lines = [error_line for error_line in error_text.splitlines() if error_line.strip()]
    error_kind = None
    if not reachable:
        error_kind = "channel_empty" if error_lines and all("404" in error_line for error_line in error_lines) else "network"
    write_json_atomic(Path(online_name), {
        "checked_at": utc_now_text(), "channel": channel, "base_url": base_url, "reachable": reachable, "error_kind": error_kind,
        "error": None if reachable else (error_text[-ONLINE_ERROR_LIMIT:] or "릴리즈 채널에 연결하지 못했습니다"),
        "auto_update": auto_update == "1", "auto_update_source": auto_update_source,
        "total": total, "services": services,
    })


def online_describe(online_name: str) -> None:
    """online.json을 observer 로그 한 줄로 요약해 출력합니다.

    Args:
        online_name (str): online.json 경로입니다.
    """
    online = read_json(Path(online_name))
    if not online:
        print("결과 없음")
        return
    if not online.get("reachable"):
        reason = "채널에 배포된 버전 없음(404)" if online.get("error_kind") == "channel_empty" else "연결 실패"
        print(f"{reason}: {str(online.get('error') or '').splitlines()[-1:] or ''}")
        return
    total = online.get("total") or {}
    newer_names = [
        f"{service_name} {service_entry.get('version')}"
        for service_name, service_entry in sorted((online.get("services") or {}).items()) if service_entry.get("newer")
    ]
    total_text = f"최신 통합 {total.get('version')}{'(새 버전)' if total.get('newer') else ''}" if total else "통합 버전 없음"
    print(f"{total_text} · 새 버전 서비스: {', '.join(newer_names) or '없음'}")


def online_next(online_name: str, installed_name: str) -> None:
    """자동 업데이트할 대상을 출력합니다. 통합 버전이 새로우면 total, 아니면 새 버전이 있는 첫 서비스, 없으면 빈 줄입니다.

    online.json을 쓴 뒤 업데이트했을 수 있어 새 버전 여부는 지금 installed.json과 다시 비교합니다(같은 ZIP을 다시 받지 않게).

    Args:
        online_name (str): online.json 경로입니다.
        installed_name (str): installed.json 경로입니다.
    """
    online = read_json(Path(online_name))
    installed = read_json(Path(installed_name))
    total = online.get("total") or {}
    if online.get("reachable") and total.get("path") and is_newer_version(str(total.get("version") or ""), installed.get("version") or "0.0.0"):
        print("total")
        return
    installed_services = installed.get("services") or {}
    for service_name, service_entry in sorted((online.get("services") or {}).items()):
        installed_version = (installed_services.get(service_name) or {}).get("version") or ""
        # 설치하지 않은 서비스는 자동으로 들이지 않습니다(버전 탭에서 직접 고릅니다).
        if installed_version and is_newer_version(str(service_entry.get("version") or ""), installed_version):
            print(service_name)
            return
    print("")


def main(arguments: list[str]) -> None:
    """명령 이름으로 처리 함수를 고릅니다.

    Args:
        arguments (list[str]): 명령과 인자입니다.
    """
    if not arguments:
        fail(__doc__ or "")
    command_name, command_arguments = arguments[0], arguments[1:]
    if command_name == "extract" and len(command_arguments) == 2:
        extract(*command_arguments)
    elif command_name == "validate" and len(command_arguments) == 2:
        validate(*command_arguments)
    elif command_name == "get" and len(command_arguments) == 2:
        get(*command_arguments)
    elif command_name == "count-active" and not command_arguments:
        count_active()
    elif command_name == "write-status" and len(command_arguments) == 6:
        write_status(*command_arguments)
    elif command_name == "write-heartbeat" and len(command_arguments) == 2:
        write_heartbeat(*command_arguments)
    elif command_name == "record" and len(command_arguments) in (5, 7):
        record(*command_arguments)
    elif command_name == "run-start" and len(command_arguments) == 4:
        run_start(*command_arguments)
    elif command_name == "run-stage" and len(command_arguments) == 5:
        run_stage(*command_arguments)
    elif command_name == "run-note" and len(command_arguments) == 4:
        run_note(*command_arguments)
    elif command_name == "prune-archives" and len(command_arguments) == 2:
        prune_archives(*command_arguments)
    elif command_name == "installed-get" and len(command_arguments) == 2:
        installed_get(*command_arguments)
    elif command_name == "make-site-env" and len(command_arguments) == 4:
        make_site_env(*command_arguments)
    elif command_name == "snapshot" and len(command_arguments) == 5:
        snapshot(*command_arguments)
    elif command_name == "json-get" and len(command_arguments) == 2:
        json_get(*command_arguments)
    elif command_name == "version-is-newer" and len(command_arguments) == 2:
        version_is_newer(*command_arguments)
    elif command_name == "download" and len(command_arguments) in (3, 4):
        download(*command_arguments)
    elif command_name == "online-summary" and len(command_arguments) == 7:
        online_summary(*command_arguments)
    elif command_name == "online-describe" and len(command_arguments) == 1:
        online_describe(*command_arguments)
    elif command_name == "online-next" and len(command_arguments) == 2:
        online_next(*command_arguments)
    else:
        fail(f"알 수 없는 명령이거나 인자 수가 다릅니다: {' '.join(arguments)}")


if __name__ == "__main__":
    main(sys.argv[1:])
