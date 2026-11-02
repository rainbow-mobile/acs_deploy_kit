# ACS 배포 키트

RB ACS를 현장 PC에 설치하고 업데이트하는 최소 구성입니다. 실행 흐름은 네 파일만 보면 됩니다.

```text
deploy.sh     최초 설치와 observer 등록
update.sh     ZIP 검증, 백업, 선택 서비스 교체, 실패 시 롤백
observer.sh   Debugger에서 올린 ZIP 감시 후 update.sh 호출
reset.sh      서비스와 observer 제거

common.sh     네 스크립트가 같이 쓰는 환경·compose 함수
release.py    ZIP 검증과 버전 이력 처리
tests/
  test-update.sh
```

`lib/`과 `systemd/` 폴더는 사용하지 않습니다. systemd 서비스 내용은 `deploy.sh`가 설치할 때 바로 생성합니다.

## 배포 흐름

1. 개발 PC의 `rb_acs`에서 `make backend.deploy`를 실행합니다.
2. 선택한 서비스만 빌드·패키징되고, 설치용 ZIP과 업데이트용 ZIP이 `~/acs-release/`에 만들어집니다.
3. S3 옵션을 선택하면 같은 ZIP을 S3에도 올리고 Slack에는 다운로드 링크를 보냅니다. ZIP과 빌드 결과물은 Git에 넣지 않습니다.
4. 최초 설치는 현장 PC에서 `deploy.sh`로 진행합니다.
5. 이후에는 Debugger Version 탭에 업데이트 ZIP을 올리면 `observer.sh`가 `update.sh`를 실행합니다.

## 최초 설치

```bash
./deploy.sh ~/acs-v1.2.3-install.zip \
  --frs-url=http://192.168.0.10:3000 \
  --moms-url=http://192.168.0.20:8080
```

| 옵션 | 기본값 | 설명 |
|---|---|---|
| `--root=<디렉터리>` | 키트 옆 `rb-acs` | 설치 디렉터리 |
| `--project=<이름>` | `rb-acs` | compose 프로젝트 이름 |
| `--gateway-url=<주소>` | `http://127.0.0.1:13000` | 실행 중 Task 확인 주소 |
| `--site-env=<파일>` | 없음 | 기존 현장 설정 복사 |
| `--site-compose=<파일>` | 없음 | 현장 compose 덮어쓰기 |
| `--online-channel=<이름>` | `main` | `acs/<채널>` 온라인 배포 채널 |
| `--online-url=<주소>` | `https://diokjo4dtg1mp.cloudfront.net/acs/main` | 별도 배포 URL을 사용할 때 덮어쓰기 |
| `--auto-update` | 사용 안 함 | 온라인 최신 버전 자동 적용 활성화 |
| `--no-auto-update` | 기본값 | 기존 온라인 자동 적용 설정도 해제 |
| `--no-systemd` | 등록함 | 시험용으로 observer 등록 생략 |

사용자 홈은 코드에 고정하지 않습니다. 기본 설치 위치는 키트 위치를 기준으로 계산하고 `--root`로 바꿀 수 있습니다.

온라인 자동배포는 기본적으로 꺼져 있습니다. 활성화할 현장에서만 다음처럼 설치합니다.

```bash
./deploy.sh acs-v1.2.3-install.zip \
  --auto-update
```

`develop` 채널을 사용하려면 `--online-channel=develop`을 함께 지정합니다.

observer는 로컬로 업로드된 ZIP을 항상 먼저 처리합니다. 로컬 ZIP이 없고 자동배포가 켜진 경우에만
`latest.json`을 조회하며, 현재보다 높은 버전의 업데이트 ZIP을 내려받아 SHA-256 검증 후 기존 `update.sh`로 적용합니다.
설치 후 `/etc/rainbow/acs-env.conf`에서 `ACS_ONLINE_AUTO_UPDATE=0`으로 바꾸면 다음 확인 주기부터 온라인 조회가 중단됩니다.

## 업데이트와 롤백

| 단계 | 처리 | 실패 시 |
|---|---|---|
| wait_tasks | 실행 중 Task 확인 | ZIP을 남기고 다음 주기에 재시도 |
| validate | 형식·arch·sha256 검사 | 설치 파일을 바꾸지 않음 |
| images | 포함된 이미지 load 및 필요 이미지 확인 | 설치 파일을 바꾸지 않음 |
| backup | MongoDB·PostgreSQL 백업 | 설치 파일을 바꾸지 않음 |
| snapshot | 현재 서비스와 설정을 롤백 ZIP으로 보관 | 설치 파일을 바꾸지 않음 |
| runtime / swap | 설정과 선택 서비스 bin 교체 | 직전 파일로 복원 |
| restart / health | 필요한 서비스만 재시작·상태 확인 | 직전 파일로 복원 후 재기동 |

- 이전 버전은 `deploy/archives/acs-rollback-*.zip`에 남고 Debugger에서 다시 적용할 수 있습니다.
- 버전과 성공·실패 이력은 `deploy/installed.json`에 남습니다.
- DB 백업은 `backups/`에 최근 3개를 유지합니다. DB 자체는 자동 롤백하지 않습니다.
- 자동 복구 가능한 검사는 빌드 단계에서 먼저 고칩니다. 손상된 ZIP처럼 고칠 수 없는 오류는 기존 설치를 보존한 채 실패 처리합니다.

```bash
./update.sh acs-v1.2.4-update.zip
./update.sh --force acs-v1.2.4-update.zip
journalctl -u acs-update-observer -f
cat /설치경로/deploy/status.json
./reset.sh
./reset.sh --purge
```

## 테스트

```bash
bash tests/test-update.sh
```

`tests/`는 운영 파일은 아니지만 설치·부분 업데이트·검증·롤백·observer가 깨지지 않았는지 한 파일로 확인하기 위해 유지합니다. 실제 컨테이너는 띄우지 않습니다.

지원 대상은 Linux amd64와 Docker Compose v2.24 이상입니다.
