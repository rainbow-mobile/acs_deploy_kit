#!/bin/bash
# reset.sh — 설치한 ACS를 내리고 observer 등록을 지운다.
# 사용법: reset.sh [--purge] [--yes]
#   기본: 컨테이너와 observer만 지우고 설치 디렉터리·DB 볼륨·백업은 남긴다(다시 deploy.sh하면 이어서 쓴다).
#   --purge: DB 볼륨과 설치 디렉터리(ACS_ROOT)·설정 파일까지 지운다. 되돌릴 수 없다.
#   --yes: 확인 질문 없이 진행한다.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"
load_acs_env

PURGE=0
ASSUME_YES=0
for argument in "$@"; do
  case "$argument" in
    --purge) PURGE=1 ;;
    --yes) ASSUME_YES=1 ;;
    *) echo "알 수 없는 옵션: $argument" >&2; exit 2 ;;
  esac
done

echo "설치 디렉터리: $ACS_ROOT (프로젝트 $ACS_PROJECT)"
[ "$PURGE" -eq 1 ] && echo "⚠️  --purge: DB 볼륨과 설치 디렉터리를 지웁니다. 되돌릴 수 없습니다."
if [ "$ASSUME_YES" -eq 0 ]; then
  read -r -p "계속할까요? [y/N] " answer
  [ "$answer" = "y" ] || [ "$answer" = "Y" ] || { echo "취소했습니다."; exit 0; }
fi

if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/acs-update-observer.service ]; then
  sudo systemctl disable --now acs-update-observer >/dev/null 2>&1 || true
  sudo rm -f /etc/systemd/system/acs-update-observer.service
  sudo systemctl daemon-reload
  echo "observer 등록을 지웠습니다."
fi

if [ -f "$ACS_ROOT/compose.yml" ]; then
  if [ "$PURGE" -eq 1 ]; then
    acs_compose down -v --remove-orphans
  else
    acs_compose down --remove-orphans
  fi
fi

if [ "$PURGE" -eq 1 ]; then
  rm -rf "${ACS_ROOT:?}"
  if [ -w "$(dirname "$ACS_ENV_FILE")" ]; then rm -f "$ACS_ENV_FILE"; else sudo rm -f "$ACS_ENV_FILE"; fi
  echo "설치 디렉터리와 설정 파일을 지웠습니다."
fi
echo "완료"
