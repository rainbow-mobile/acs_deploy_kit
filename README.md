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
예전 이름 `acs-observer.sh`·`acs-update.sh`·`lib/release_tool.py`는 2026-11-02 정리 전에 설치한 현장 PC 호환용 얇은 파일입니다.
그 PC의 systemd 서비스는 `acs-observer.sh`를 부르고, 키트를 받기 전에 떠 있던 옛 observer는 `lib/release_tool.py`·`acs-update.sh`를 부르므로
새 `observer.sh`·`release.py`·`update.sh`로 넘겨 줍니다. `deploy.sh`를 다시 실행하면 서비스가 `observer.sh`를 직접 부르도록 바뀝니다. 지우지 마세요.

## 배포 흐름

1. 개발 PC의 `rb_acs`에서 `make backend.deploy`를 실행합니다. 선택한 서비스만 테스트·빌드해 서비스별 ZIP을 만들고 태그를 push합니다.
2. GitHub Actions가 서비스 ZIP을 S3 `acs/<채널>/<서비스>/`에 올립니다. 통합 묶음을 고르면 서비스별 최신 ZIP과 이미지를 묶은
   통합 ZIP(`acs/<채널>/<통합버전>.amd64.zip`)과 `latest.json`도 올립니다. 채널은 배포한 브랜치(main, develop)입니다.
3. 최초 설치는 현장 PC에서 `deploy.sh`로 진행합니다. 기본은 온라인(`latest.json`의 통합 ZIP)이고, 인터넷이 없으면 `--input`으로 ZIP을 지정합니다.
4. 이후에는 Debugger Version 탭에 서비스 ZIP·업데이트 ZIP을 올리면 `observer.sh`가 `update.sh`를 실행합니다.

## 최초 설치

온라인 설치가 기본입니다(2026-11-03). `--mode`로 채널을 고르고, 오프라인 설치만 `--input`으로 ZIP을 지정합니다.

```bash
./deploy.sh                                  # 온라인 main 채널 최신 통합 ZIP으로 설치
./deploy.sh --mode=develop                   # 온라인 develop 채널(개발 빌드)
./deploy.sh --auto-update                    # 설치 후 온라인 자동 업데이트도 켬
./deploy.sh --input=/path/acs-1.2.3.amd64.zip \
  --frs-url=http://192.168.0.10:3000 \
  --moms-url=http://192.168.0.20:8080        # 오프라인: 가져온 통합 ZIP으로 설치
```

| 옵션 | 기본값 | 설명 |
|---|---|---|
| `--mode=<채널>` | `main` | 온라인 배포 채널(`acs/<채널>`). `develop`이면 개발 빌드 |
| `--input=<파일>` | 없음(온라인) | 오프라인 설치에 쓸 통합 ZIP(이미지 포함). 주면 온라인으로 받지 않음 |
| `--reinstall` | 사용 안 함 | 설치된 버전이 온라인 최신과 같거나 높아도 다시 받아 설치 |
| `--root=<디렉터리>` | 키트 옆 `rb-acs` | 설치 디렉터리 |
| `--project=<이름>` | `rb-acs` | compose 프로젝트 이름 |
| `--gateway-url=<주소>` | `http://127.0.0.1:13000` | 실행 중 Task 확인 주소 |
| `--site-env=<파일>` | 없음 | 기존 현장 설정 복사 |
| `--site-compose=<파일>` | 없음 | 현장 compose 덮어쓰기 |
| `--online-url=<주소>` | `https://diokjo4dtg1mp.cloudfront.net/acs/<채널>` | 별도 배포 URL을 사용할 때 덮어쓰기 |
| `--auto-update` | 사용 안 함 | 온라인 최신 버전 자동 적용 활성화 |
| `--no-auto-update` | 기본값 | 기존 온라인 자동 적용 설정도 해제 |
| `--no-systemd` | 등록함 | 시험용으로 observer 등록 생략 |

ZIP 경로를 옵션 없이 쓰면(`./deploy.sh acs.zip`) `--input=`을 쓰라고 안내하고 멈춥니다. 예전 옵션 `--online`은 아무것도 하지 않고,
`--online-channel=<이름>`은 `--mode`와 같습니다. 고른 채널은 `/etc/rainbow/acs-env.conf`의 `ACS_RELEASE_CHANNEL`에 남아
observer 자동 업데이트와 `update.sh --online`도 같은 채널을 봅니다. 다시 설치할 때 `--mode`를 주지 않으면 기록된 채널을 씁니다.

`deploy.sh`는 큰 ZIP을 받기 전에 사전 환경부터 준비합니다(sudo 비밀번호를 물을 수 있음). Docker·Compose가 없고 인터넷이 되면 apt로
설치하고(`docker.io`, `docker-compose-v2`, Compose v2.24 이상 필요) 데몬을 켜며, 현재 사용자가 docker를 못 쓰면 docker 그룹에 추가한 뒤
`sg docker`로 같은 옵션 그대로 다시 실행해 이어서 설치합니다. 다시 로그인하지 않아도 됩니다. `inotify-tools`도 없으면 설치합니다.

온라인 설치·업데이트는 `latest.json`의 버전을 설치된 버전(`deploy/installed.json`)과 먼저 비교하고, 더 새 버전이 있을 때만 큰 ZIP을 받습니다.
같거나 낮으면 "이미 최신"을 알리고 끝냅니다(`deploy.sh --reinstall`로 다시 받기). 이 확인은 sudo·사전 환경 준비보다 먼저 합니다.
큰 ZIP을 받는 동안에는 3초마다 `📥 1.0.2.amd64.zip 143/530MB 27% · 남은 시간 약 16s · 23MB/s · 경과 6s` 같은 줄을 찍고, 끝나면 걸린 시간을 찍습니다
(observer 로그에도 같은 줄로 남습니다). 받는 파일은 `deploy.sh`는 설치 디렉터리의 `.download/`, `update.sh --online`은 `deploy/.manual-online-update.zip`에
두고, 끝나거나 실패하거나 Ctrl+C·종료 신호로 멈추면 지웁니다. 전원이 꺼지는 등으로 남은 파일은 다음 실행이 시작할 때 지웁니다.

사용자 홈은 코드에 고정하지 않습니다. 기본 설치 위치는 키트 위치를 기준으로 계산하고 `--root`로 바꿀 수 있습니다.
온라인 자동배포는 기본적으로 꺼져 있고 `--auto-update`를 준 현장에서만 켜집니다. Debugger 버전 탭에서도 켜고 끌 수 있고,
그 값(`deploy/auto-update.json`)이 설치 설정 파일(`ACS_ONLINE_AUTO_UPDATE`)보다 우선합니다.

### 온라인 최신 버전 표시와 버전 탭 온라인 업데이트 (2026-11-04)

인터넷은 호스트 observer만 씁니다. 인터넷이 되는 현장에서만 동작하고, 안 되면 짧게 실패하고 넘어갑니다.

- observer가 `ONLINE_CHECK_INTERVAL_SEC`(기본 300초)마다, 시작·업데이트 직후, 버전 탭 "다시 확인" 때 채널의 `latest.json`(통합)과
  `<서비스>/version.json`(서비스별)을 받아 `deploy/online.json`(최신 버전, 설치 버전과 비교한 새 버전 여부, 연결 여부)을 씁니다.
  처음 두 파일을 받지 못하면 인터넷이 없는 것으로 보고 나머지는 묻지 않습니다. 네트워크를 아예 쓰지 않을 현장은 `ACS_ONLINE_CHECK=0`.
- 버전 탭 요청은 Common이 `deploy/requests/<시각>-<종류>.json`으로 남깁니다. `check`는 바로 다시 조회하고, `update`(target=`total` 또는
  서비스 이름)는 통합 업데이트 ZIP(`update/<버전>.amd64.zip`) 또는 서비스 ZIP(`<서비스>/<버전>.zip`)을 받아 sha256을 확인한 뒤
  `observe/`에 넣습니다(출처 `ui-online`). 그다음은 업로드 ZIP과 같이 실행 중 Task 대기·강제 적용·실패 처리를 거칩니다.
- 자동 업데이트가 켜져 있으면 새 통합 버전을, 없으면 새 버전이 있는 설치된 서비스를 하나씩 받아 적용합니다(출처 `online-auto`).
- 로컬로 올린 ZIP이 있으면 그것을 먼저 처리합니다. 서비스 ZIP의 sha256은 새로 배포한 서비스부터 `version.json`에 있고, 없으면
  `update.sh`가 ZIP 안 파일별 sha256으로 검증합니다.

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
./update.sh --online                    # main 채널 최신 버전을 지금 수동 적용
./update.sh --force acs-v1.2.4-update.zip
./update.sh --force --online            # 실행 중 Task가 있어도 온라인 최신 버전 적용
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

## 업데이트 실행 기록과 출처 (2026-11-03)

업데이트할 때마다 `deploy/runs/<실행ID>.json`(최근 30개)에 실행 기록을 남기고, Debugger 버전 탭 "업데이트 이력"이 보여 줍니다.

- 출처: `ui-upload`(버전 탭 업로드)·`ui-rollback`(보관본 되돌리기)·`online-auto`(observer 자동)·`online-manual`(`update.sh --online`)·
  `offline-file`(누군가 `observe/`에 직접 넣은 ZIP)·`cli`(`update.sh <ZIP>` 직접 실행)·`install`(최초 설치). Common과 observer가
  ZIP 옆 `<ZIP>.meta.json`에 출처와 실행 ID를 남기고, Task를 기다렸다 다시 시도해도 같은 기록을 이어 씁니다. `update.sh --source=... --run-id=...`로도 줄 수 있습니다.
- 단계별 시작·끝 시각·상태·메시지(감지 → 대기 → 검증 → 이미지 → 백업 → 보관 → 설정 → bin 교체 → 재시작 → 헬스체크 → 마무리/되돌림),
  결과, 멈춘 단계(되돌림으로 끝났으면 실제로 실패한 단계), 경고(`warn`)·에러를 남깁니다.
- 업데이트 전 버전 보관본은 `deploy/settings.json`의 `archive_keep_count`(기본 시나리오 정책, Common이 씀)만큼 남기고 오래된 것부터 지웁니다. 파일이 없으면 3개입니다.
- 업데이트가 대기·진행 중인 동안 ACS는 새 Task(외부 요청 포함)를 받지 않습니다(Common → Task·External).

## 실패 ZIP(failed/)과 실패 이유 (2026-11-04)

observer는 `update.sh` 종료 코드가 0(적용 완료)·75(실행 중 Task 대기, ZIP을 두고 다시 시도)가 아니면 ZIP을 `deploy/failed/`(최근 3개)로 옮겨 같은 ZIP을
계속 다시 적용하지 않게 합니다. 1은 검증 실패, 또는 바꾼 뒤 실패해 되돌린 경우이고, 2는 사용법·옵션 오류입니다.
`update.sh`가 단계 기록 없이 끝나면(로그를 열기 전 옵션·설정 오류, 예기치 못한 종료 등) observer가 종료 코드와 stderr 마지막 3줄을
실행 기록 에러·`status.json`·`update.log`에 남깁니다. 그래서 failed/로 옮긴 이유를 Debugger 업데이트 이력에서 볼 수 있습니다.
