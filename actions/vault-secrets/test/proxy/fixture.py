#!/usr/bin/env python3
"""Local HTTPS Vault, OIDC, and CONNECT-proxy fixtures; fake credentials only."""

import http.server
import json
import os
from pathlib import Path
import select
import socket
import ssl
import subprocess
import sys
import threading
import time

HOST = "vault-ospo-staging.eng-svc.aws.tenstorrent.com"
OIDC_HOST = "oidc.fixture.invalid"
ROOT = Path(os.environ.get("RUNNER_TEMP", "/tmp")) / "vault-secrets-proxy-fixture"
# prepare.sh turns the short name `proxy-test` into <org>--<repo>--proxy-test.
ROLE = os.environ.get("GITHUB_REPOSITORY", "").lower().replace("/", "--") + "--proxy-test"


def record(kind, value):
    with (ROOT / "requests.jsonl").open("a") as out:
        out.write(json.dumps({"kind": kind, "value": value}) + "\n")


class Endpoint(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def respond(self, value, status=200):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        assert self.path == "/v1/auth/jwt-github/login"
        assert body == {"role": ROLE, "jwt": "fake-oidc-jwt"}
        record("login", self.path)
        if (ROOT / "deny-login").exists():
            self.respond({"errors": ["fixture: permission denied"]}, 403)
        else:
            self.respond({"auth": {"client_token": "fake-vault-token"}})

    def do_GET(self):
        if self.path.startswith("/oidc?"):
            # login.sh sends "bearer"; the scheme is not case-sensitive.
            assert self.headers["Authorization"].lower() == "bearer fake-request-token"
            record("oidc", self.path)
            self.respond({"value": "fake-oidc-jwt"})
        elif self.path.startswith("/v1/sys/health?"):
            record("health", self.path)
            self.respond({"initialized": True, "sealed": False})
        else:
            assert self.headers["X-Vault-Token"] == "fake-vault-token"
            record("secret", self.path)
            # Give the watchdog time to attach to the real Node process.
            time.sleep(1)
            if self.path == "/v1/github/token/proxy-test":
                self.respond({"data": {"token": "fake-github-token"}})
            elif self.path == "/v1/kv/data/proxy-test":
                self.respond(
                    {
                        "data": {
                            "data": {
                                "value": "fake-kv-value",
                                "nested": {"value": "fake-nested-value"},
                                "multiline": "fake-first\nfake-second",
                            }
                        }
                    }
                )
            else:
                self.respond({"errors": ["fixture: unknown path"]}, 404)


def serve():
    vault = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Endpoint)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(ROOT / "cert.pem", ROOT / "key.pem")
    vault.socket = context.wrap_socket(vault.socket, server_side=True)
    oidc = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Endpoint)
    corporate = os.environ.get("OIDC_ROUTE") == "corporate-proxy"
    if corporate:
        oidc.socket = context.wrap_socket(oidc.socket, server_side=True)

    class Proxy(http.server.BaseHTTPRequestHandler):
        target = HOST + ":443"
        destination = vault.server_address
        event = "connect"

        def log_message(self, *_args):
            pass

        def do_CONNECT(self):
            record(self.event, self.path)
            if self.path != self.target:
                self.send_error(403)
                return
            # Never forward to the real Vault: only this test's loopback TLS server.
            with socket.create_connection(self.destination) as peer:
                self.send_response(200)
                self.end_headers()
                streams = [self.connection, peer]
                while True:
                    readable, _, _ = select.select(streams, [], [], 5)
                    if not readable:
                        return
                    for source in readable:
                        data = source.recv(65536)
                        if not data:
                            return
                        (peer if source is self.connection else self.connection).sendall(data)

    proxy = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Proxy)
    class EgressProxy(Proxy):
        target = OIDC_HOST + ":443"
        destination = oidc.server_address
        event = "egress-connect"

    egress = http.server.ThreadingHTTPServer(("127.0.0.1", 0), EgressProxy)
    for server in (vault, oidc, egress):
        threading.Thread(target=server.serve_forever, daemon=True).start()
    (ROOT / "ready.json").write_text(
        json.dumps({"proxy": proxy.server_port, "oidc": oidc.server_port, "egress": egress.server_port})
    )
    proxy.serve_forever()


def start():
    ROOT.mkdir()
    (ROOT / "requests.jsonl").touch()
    (ROOT / "cert.cnf").write_text(
        "[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN="
        + HOST
        + "\n[ext]\nsubjectAltName=DNS:"
        + HOST
        + ",DNS:"
        + OIDC_HOST
        + "\n"
    )
    subprocess.run(
        [
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            str(ROOT / "key.pem"),
            "-out",
            str(ROOT / "cert.pem"),
            "-days",
            "1",
            "-config",
            str(ROOT / "cert.cnf"),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    with (ROOT / "server.log").open("w") as log:
        process = subprocess.Popen(
            [sys.executable, __file__, "serve"],
            start_new_session=True,
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=log,
        )
    (ROOT / "pid").write_text(str(process.pid))
    for _ in range(100):
        if (ROOT / "ready.json").exists():
            break
        if process.poll() is not None:
            raise RuntimeError("Fixture exited before startup")
        time.sleep(0.05)
    ports = json.loads((ROOT / "ready.json").read_text())
    with open(os.environ["GITHUB_OUTPUT"], "a") as out:
        out.write("port=" + str(ports["proxy"]) + "\n")
    with open(os.environ["GITHUB_ENV"], "a") as out:
        out.write("NODE_EXTRA_CA_CERTS=" + str(ROOT / "cert.pem") + "\n")
        out.write("CURL_CA_BUNDLE=" + str(ROOT / "cert.pem") + "\n")
        out.write("ACTIONS_ID_TOKEN_REQUEST_TOKEN=fake-request-token\n")
        if os.environ.get("OIDC_ROUTE") == "corporate-proxy":
            # An unresolvable OIDC hostname forces use of the inherited egress
            # proxy, which refuses Vault. The Vault proxy refuses OIDC.
            out.write("ACTIONS_ID_TOKEN_REQUEST_URL=https://" + OIDC_HOST + "/oidc?test=1\n")
            for name in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"):
                out.write(name + "=http://127.0.0.1:" + str(ports["egress"]) + "\n")
            out.write("NO_PROXY=" + HOST + "\nno_proxy=" + HOST + "\n")
        else:
            out.write(
                "ACTIONS_ID_TOKEN_REQUEST_URL=http://127.0.0.1:" + str(ports["oidc"]) + "/oidc?test=1\n"
            )
            # Vault must still use Tailscale even with an inherited wildcard.
            out.write("NO_PROXY=*\nno_proxy=*\n")


def verify():
    events = [json.loads(line) for line in (ROOT / "requests.jsonl").read_text().splitlines()]
    assert sum(event["kind"] == "oidc" for event in events) == 2
    assert sum(event["kind"] == "login" for event in events) == 2
    assert {event["value"] for event in events if event["kind"] == "connect"} == {HOST + ":443"}
    assert {event["value"] for event in events if event["kind"] == "secret"} == {
        "/v1/github/token/proxy-test",
        "/v1/kv/data/proxy-test",
    }
    assert sum(event["kind"] == "health" for event in events) == 2
    corporate = os.environ.get("OIDC_ROUTE") == "corporate-proxy"
    bypass = HOST if corporate else "*"
    assert os.environ["NO_PROXY"] == bypass and os.environ["no_proxy"] == bypass
    egress = [event["value"] for event in events if event["kind"] == "egress-connect"]
    if corporate:
        assert egress == [OIDC_HOST + ":443"] * 2
    else:
        assert not egress
    print(
        "PASS: Vault used its CONNECT proxy; OIDC preserved the runner route ("
        + ("corporate proxy" if corporate else "direct") + "); inherited proxy settings stayed unchanged."
    )


if __name__ == "__main__":
    command = sys.argv[1]
    if command == "serve":
        serve()
    elif command == "start":
        start()
    elif command == "deny":
        (ROOT / "deny-login").touch()
    elif command == "verify":
        verify()
    elif command == "stop":
        pid_file = ROOT / "pid"
        if pid_file.exists():
            pid = int(pid_file.read_text())
            args = subprocess.run(
                ["ps", "-p", str(pid), "-o", "args="], capture_output=True, text=True
            ).stdout
            if "fixture.py serve" in args:
                os.kill(pid, 15)
    else:
        raise SystemExit("Unknown fixture command")
