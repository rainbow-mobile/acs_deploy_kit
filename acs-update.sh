#!/bin/bash
# acs-update.sh — 예전 이름 호환용입니다(2026-11-02 update.sh로 이름 변경). 키트를 받기 전에 떠 있던 옛 observer가 이 경로로 업데이트를 부릅니다.
exec /bin/bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/update.sh" "$@"
