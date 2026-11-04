#!/bin/bash
# acs-observer.sh — 예전 이름 호환용입니다. 2026-11-02 키트 정리(observer.sh로 이름 변경) 전에 설치한 현장 PC의
# systemd 서비스(acs-update-observer)가 ExecStart로 이 경로를 부르므로, 서비스를 다시 등록하지 않아도 새 observer.sh가 돌게 넘겨 줍니다.
# deploy.sh를 다시 실행하면 서비스가 observer.sh를 직접 부르도록 바뀝니다.
exec /bin/bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/observer.sh" "$@"
