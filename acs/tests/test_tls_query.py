"""TLS 전환 후 배포 키트의 Gateway 실행 조회를 검증합니다."""

from __future__ import annotations

import contextlib
import io
import shutil
import ssl
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from acs import release


class TaskHandler(BaseHTTPRequestHandler):
    """HTTPS Task 실행 목록을 반환합니다."""

    def do_GET(self) -> None:
        """실행 중 Task 한 개를 반환합니다."""
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'[{"state":"running"}]')

    def log_message(self, message: str, *arguments: object) -> None:
        """테스트 서버의 접속 로그를 출력하지 않습니다."""


@unittest.skipUnless(shutil.which("openssl"), "openssl이 필요합니다")
class TlsGatewayQueryTest(unittest.TestCase):
    """기본 HTTP 주소를 현장 HTTPS 주소로 전환하고 인증서를 검증합니다."""

    def setUp(self) -> None:
        """SAN이 localhost인 임시 HTTPS 서버를 시작합니다."""
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary_directory.name)
        self.certificate = self.directory / "server.crt"
        self.private_key = self.directory / "server.key"
        subprocess.run(
            ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
             "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
             "-keyout", str(self.private_key), "-out", str(self.certificate)],
            check=True, capture_output=True,
        )
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), TaskHandler)
        tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls_context.load_cert_chain(self.certificate, self.private_key)
        self.server.socket = tls_context.wrap_socket(self.server.socket, server_side=True)
        self.server_thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.server_thread.start()
        self.site_env = self.directory / "site.env"
        self.site_env.write_text(
            f"HTTPS_ENABLED=true\nACS_PUBLIC_ORIGIN=https://localhost:{self.server.server_port}\n"
            f"TLS_CERT_PATH={self.certificate}\nTLS_CA_PATH={self.certificate}\n",
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        """임시 서버와 인증서를 정리합니다."""
        self.server.shutdown()
        self.server.server_close()
        self.server_thread.join()
        self.temporary_directory.cleanup()

    def test_uses_https_public_origin_and_trusted_certificate(self) -> None:
        """TLS가 켜지면 기존 기본 URL 대신 SAN이 맞는 HTTPS 주소로 조회합니다."""
        output = io.StringIO()

        with contextlib.redirect_stdout(output):
            release.query_active("http://127.0.0.1:13000", str(self.site_env))

        self.assertEqual(output.getvalue().strip(), "1")

    def test_replaces_previous_http_gateway_address(self) -> None:
        """이전 설치 설정의 HTTP 주소도 현장 HTTPS 공개 출처로 전환합니다."""
        output = io.StringIO()

        with contextlib.redirect_stdout(output):
            release.query_active("http://192.168.60.200:13000", str(self.site_env))

        self.assertEqual(output.getvalue().strip(), "1")

    def test_rejects_untrusted_certificate(self) -> None:
        """잘못된 CA를 지정해도 인증서 검증을 우회하지 않습니다."""
        self.site_env.write_text(self.site_env.read_text().replace(str(self.certificate), str(self.directory / "missing.crt")))
        output = io.StringIO()

        with contextlib.redirect_stdout(output):
            release.query_active("http://127.0.0.1:13000", str(self.site_env))

        self.assertEqual(output.getvalue().strip(), "unknown")

    def test_shell_task_check_uses_https_settings(self) -> None:
        """업데이트 전 Task 확인도 TLS 현장 설정을 통해 조회합니다."""
        script = Path(__file__).resolve().parents[1] / "common.sh"
        result = subprocess.run(
            ["bash", "-c", '. "$1"; ACS_ROOT="$2"; ACS_GATEWAY_URL=http://127.0.0.1:13000; active_task_count',
             "_", str(script), str(self.directory)],
            capture_output=True, text=True, check=True,
        )

        self.assertEqual(result.stdout.strip(), "1")


if __name__ == "__main__":
    unittest.main()
