#!/usr/bin/env python3
"""Exercise the campus_net_guard probe -> login -> verify flow locally."""

from __future__ import annotations

import http.server
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from urllib.parse import parse_qs


class PortalHandler(http.server.BaseHTTPRequestHandler):
    server_version = "CampusNetGuardTest/1.0"

    def log_message(self, *_args: object) -> None:
        return

    def _has_auth_cookie(self) -> bool:
        return "campus-auth=ok" in self.headers.get("Cookie", "")

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/probe":
            if self.server.authenticated and self._has_auth_cookie():
                self.send_response(204)
                self.end_headers()
                return
            self.send_response(302)
            self.send_header("Location", "/login")
            self.end_headers()
            return

        self.send_response(404)
        self.end_headers()

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/login":
            self.send_response(404)
            self.end_headers()
            return

        length = int(self.headers.get("Content-Length", "0"))
        values = parse_qs(self.rfile.read(length).decode("utf-8"), keep_blank_values=True)
        username = values.get("username", [""])[0]
        password = values.get("password", [""])[0]
        if username != "student-001" or password != "local-test-secret":
            self.send_response(403)
            self.end_headers()
            self.wfile.write(b"invalid")
            return

        self.server.authenticated = True
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Set-Cookie", "campus-auth=ok; Path=/")
        body = b"success"
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main() -> int:
    binary = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("build/campus_net_guard")
    if not binary.is_file():
        print(f"missing binary: {binary}", file=sys.stderr)
        return 2

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), PortalHandler)
    server.authenticated = False
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    try:
        with tempfile.TemporaryDirectory(prefix="campus-net-guard-test-") as directory:
            root = Path(directory)
            password_file = root / "password"
            config_file = root / "config.conf"
            cookie_file = root / "cookies.txt"
            password_file.write_text("local-test-secret\n", encoding="utf-8")
            password_file.chmod(0o600)

            port = server.server_address[1]
            config_file.write_text(
                "\n".join(
                    [
                        f"probe_url=http://127.0.0.1:{port}/probe",
                        "probe_success_status=204",
                        f"auth_url=http://127.0.0.1:{port}/login",
                        "auth_method=POST",
                        "request_format=form",
                        "username=student-001",
                        "local_ipv4=127.0.0.1",
                        "operator=test",
                        "field.client_ip={local_ipv4}",
                        "field.operator={operator}",
                        f"password_file={password_file}",
                        f"cookie_file={cookie_file}",
                        "auth_success_status=200",
                        "auth_success_contains=success",
                        "auth_failure_contains=invalid",
                        "verify_delay_ms=0",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            config_file.chmod(0o600)

            result = subprocess.run(
                [os.fspath(binary), "--config", os.fspath(config_file), "--once"],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
            output = result.stdout + result.stderr
            if result.returncode != 0:
                print(output, file=sys.stderr)
                return result.returncode or 1
            if "network restored" not in output:
                print(f"unexpected output:\n{output}", file=sys.stderr)
                return 1
            if "local-test-secret" in output:
                print("secret leaked to process output", file=sys.stderr)
                return 1
            print("campus_net_guard smoke test passed")
            return 0
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


if __name__ == "__main__":
    raise SystemExit(main())
