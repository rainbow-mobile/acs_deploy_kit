"""ACS 릴리즈 ZIP 처리 보조 도구입니다. acs-update.sh·acs-observer.sh가 부릅니다.

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
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import socket
import sys
import tempfile
import time
import zipfile
from datetime import datetime, timezone
from pathlib import Path

# 릴리즈 매니페스트 종류와 지원 형식 버전입니다(rb_acs scripts/deployment/build_release.py).
RELEASE_KIND = "acs.release"
SUPPORTED_FORMAT_VERSION = 1
# Task 실행이 끝난 상태입니다(rb_acs task execution_repository.TERMINAL_STATES). 그 밖의 상태는 실행 중으로 봅니다.
TERMINAL_EXECUTION_STATES = {"completed", "stopped", "cancelled", "restarted", "idle"}
# installed.json에 남기는 적용 이력 수입니다.
HISTORY_LIMIT = 20


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


def write_heartbeat(heartbeat_name: str, interval_seconds: str) -> None:
    """observer heartbeat(observer.json)를 씁니다. 화면은 경과 시간으로 observer 동작 여부를 판단합니다.

    Args:
        heartbeat_name (str): observer.json 경로입니다.
        interval_seconds (str): observer 확인 주기(초)입니다.
    """
    write_json_atomic(Path(heartbeat_name), {
        "updated_at": int(time.time() * 1000), "interval_sec": int(interval_seconds), "host": socket.gethostname(), "pid": os.getppid(),
    })


def record(installed_name: str, staging_name: str, images_tag: str, result: str, message: str) -> None:
    """적용 결과를 installed.json에 남깁니다. 성공이면 전체·서비스별 버전과 이미지 태그를 바꾸고, 실패면 이력만 더합니다.

    Args:
        installed_name (str): installed.json 경로입니다.
        staging_name (str): 푼 디렉터리입니다.
        images_tag (str): 적용 후 Gateway·Zenoh router 이미지 태그입니다.
        result (str): success 또는 failed입니다.
        message (str): 결과 메시지입니다.
    """
    installed_path = Path(installed_name)
    installed = read_json(installed_path)
    manifest = load_manifest(Path(staging_name))
    applied_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if result == "success":
        installed_services = installed.get("services") or {}
        for service_name, service_entry in (manifest.get("services") or {}).items():
            installed_services[service_name] = {"version": service_entry["version"], "sha256": service_entry["sha256"], "installed_at": applied_at}
        installed.update({
            "version": manifest["version"], "git_commit": manifest.get("git_commit"), "installed_at": applied_at,
            "images_tag": images_tag, "services": installed_services,
        })
    history = installed.get("history") or []
    history.append({
        "version": manifest.get("version"), "result": result, "at": applied_at, "message": message,
        "services": sorted(manifest.get("services") or {}),
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

    POSTGRES_PASSWORD는 예시 값으로 설치하지 않도록 무작위로 만들고, FRS·MOMS 주소는 받은 값이 있으면 넣습니다.
    설치 후 DB 비밀번호를 바꾸면 기존 DB에 접속하지 못하므로 이 파일은 처음 한 번만 만듭니다.

    Args:
        archive_name (str): 릴리즈 ZIP 경로입니다.
        site_env_name (str): 만들 site.env 경로입니다.
        frs_url (str): FRS REST 주소입니다. 비면 예시 값을 둡니다.
        moms_url (str): SMC MOMS 주소입니다. 비면 예시 값을 둡니다.
    """
    with zipfile.ZipFile(archive_name) as release_archive:
        example_lines = release_archive.read("runtime/site.env.example").decode("utf-8").splitlines()
    replacements = {"POSTGRES_PASSWORD": secrets.token_urlsafe(24)}
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
        "created_at": taken_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "git_commit": installed.get("git_commit"),
        "arch": architecture,
        "services": {
            service_name: {
                "version": (installed_services.get(service_name) or {}).get("version") or previous_version,
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
    elif command_name == "record" and len(command_arguments) == 5:
        record(*command_arguments)
    elif command_name == "installed-get" and len(command_arguments) == 2:
        installed_get(*command_arguments)
    elif command_name == "make-site-env" and len(command_arguments) == 4:
        make_site_env(*command_arguments)
    elif command_name == "snapshot" and len(command_arguments) == 5:
        snapshot(*command_arguments)
    else:
        fail(f"알 수 없는 명령이거나 인자 수가 다릅니다: {' '.join(arguments)}")


if __name__ == "__main__":
    main(sys.argv[1:])
