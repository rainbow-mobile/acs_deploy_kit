"""예전 경로 호환용입니다(2026-11-02 키트 정리로 release.py로 옮김).

키트를 새로 받기 전에 떠 있던 옛 observer는 이 경로로 heartbeat·상태 기록 명령을 부릅니다. 새 release.py에 그대로 넘겨
서비스를 다시 시작하기 전까지도 observer가 멈추지 않게 합니다.
"""

import runpy
import sys
from pathlib import Path

if __name__ == "__main__":
    release_path = Path(__file__).resolve().parents[1] / "release.py"
    sys.argv[0] = str(release_path)
    runpy.run_path(str(release_path), run_name="__main__")
