#!/usr/bin/env bash
# Test helper for .github/workflows/vault-secrets-test.yml. Not used by the action.
# Checks the facts of the real curl on this runner that login.sh and
# read-token.sh use to find a request that curl did not send (not_sent_cause).
# vault-api-cases.sh uses a fake curl with these same values.
#   - not sent: exit 7 (connection refused), 28 (TLS handshake stalled), 28
#     (proxy CONNECT stalled) and 56 (proxy answers CONNECT with 502) give
#     time_pretransfer 0 and http_code 000;
#   - sent: a request to a server that reads it and does not answer gives exit
#     28 and time_pretransfer > 0.
# Local servers on 127.0.0.1 only (python3). No Vault, no secret.
set -euo pipefail

command -v python3 >/dev/null || { echo "::error::curl-facts-cases.sh needs python3"; exit 1; }
work="$(mktemp -d)"
server_pid=""
# shellcheck disable=SC2329 # Called by the EXIT trap.
cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT
status=0
curl --version | head -n 1

# The same -w line as login.sh and read-token.sh.
write_out="$(sed -n "s/^WRITE_OUT='\(.*\)'$/\1/p" "$(dirname "${BASH_SOURCE[0]}")/../login.sh")"
[ -n "$write_out" ] || { echo "::error::no WRITE_OUT in login.sh"; exit 1; }

# Port 1: silent (reads, never answers). Port 2: a proxy that answers CONNECT
# with 502. Port 3: a proxy that reads CONNECT and never answers.
cat >"$work/server.py" <<'PY'
import socket, sys, threading, time
def serve(sock, mode):
    while True:
        conn, _ = sock.accept()
        def handle(c=conn):
            c.recv(65536)
            if mode == "502":
                c.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
            time.sleep(30)
            c.close()
        threading.Thread(target=handle, daemon=True).start()
ports = []
for mode in ("silent", "502", "silent"):
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    s.listen(8)
    ports.append(str(s.getsockname()[1]))
    threading.Thread(target=serve, args=(s, mode), daemon=True).start()
print(" ".join(ports), flush=True)
time.sleep(120)
PY
python3 "$work/server.py" >"$work/ports" &
server_pid=$!
for _ in $(seq 50); do [ -s "$work/ports" ] && break; sleep 0.1; done
read -r silent proxy502 proxysilent <"$work/ports"
# A free port with no listener.
closed="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"

# Runs curl with the write-out line. Sets rc and the -w values.
probe() {
  local out
  rc=0
  out="$(curl -sS --connect-timeout 2 --max-time 3 -w "$write_out" "$@" 2>/dev/null)" || rc=$?
  read -r code proxy_code _ t_start _ <<<"${out##*$'\n'}" || true
}

# check <title> <want rc> <want proxy code> <sent|not-sent> curl args...
check() {
  local title="$1" want_rc="$2" want_proxy="$3" want="$4" got=not-sent
  shift 4
  probe "$@"
  [[ "$t_start" =~ ^0(\.0+)?$ ]] || got=sent
  if [ "$rc" != "$want_rc" ] || [ "$code" != 000 ] || [ "$proxy_code" != "$want_proxy" ] || [ "$got" != "$want" ]; then
    echo "::error::$title: curl exit $rc, http_code '$code', http_connect '$proxy_code', time_pretransfer '$t_start'; expected exit $want_rc, 000, $want_proxy, $want"
    status=1
  else
    echo "OK: $title: exit $rc, time_pretransfer $t_start ($want)"
  fi
}

check 'connection refused' 7 000 not-sent "https://127.0.0.1:$closed/v1/auth/jwt-github/login"
check 'TLS handshake stalled' 28 000 not-sent "https://127.0.0.1:$silent/v1/auth/jwt-github/login"
check 'request sent, no answer' 28 000 sent -X POST --data-binary x "http://127.0.0.1:$silent/v1/auth/jwt-github/login"
check 'proxy answers CONNECT with 502' 56 502 not-sent \
  --proxy "http://127.0.0.1:$proxy502" --noproxy '' https://vault.invalid/v1/auth/jwt-github/login
check 'proxy CONNECT stalled' 28 000 not-sent \
  --proxy "http://127.0.0.1:$proxysilent" --noproxy '' https://vault.invalid/v1/auth/jwt-github/login

exit "$status"
