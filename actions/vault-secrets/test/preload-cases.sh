#!/usr/bin/env bash
# Test helper for .github/workflows/vault-secrets-test.yml. Not used by the action.
# Runs proxy-agent.cjs (network-mode userspace) with the node on PATH, without
# the network. Checks:
#   - the preload refuses a missing proxy and a proxy that is not on loopback;
#   - the new global agents have the same options as Node's own global agents
#     (no timeout of the preload), plus only the proxy;
#   - a request to Vault goes to the proxy, also with NO_PROXY=*.
# Needs Node 24.5 or newer on PATH. Uses no token and no secret.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
preload="$here/../proxy-agent.cjs"
status=0

version="$(node -p 'process.versions.node')"
IFS=. read -r major minor _ <<<"$version"
if [ "$major" -lt 24 ] || { [ "$major" -eq 24 ] && [ "$minor" -lt 5 ]; }; then
  echo "::error::preload-cases.sh needs Node 24.5 or newer on PATH (found $version)"
  exit 1
fi

# The preload refuses a bad proxy setting before any request.
for proxy in '' http://10.0.0.1:1055 http://localhost:1055 socks5://127.0.0.1:1055 http://127.0.0.1:1055/x; do
  rc=0
  out="$(env -i PATH="$PATH" VAULT_SECRETS_PROXY_URL="$proxy" node --require="$preload" -e '' 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] || [[ "$out" != *'proxy setting is missing or invalid'* ]]; then
    echo "::error::preload accepted proxy '$proxy'"
    status=1
  else
    echo "OK: refused: proxy '$proxy'"
  fi
done

# Options: the same as Node's own global agents, plus proxyEnv.
rc=0
out="$(env -i PATH="$PATH" PRELOAD="$preload" node -e '
  const http = require("node:http"), https = require("node:https");
  const before = [http.globalAgent.options, https.globalAgent.options].map((o) => JSON.stringify(o));
  process.env.VAULT_SECRETS_PROXY_URL = "http://127.0.0.1:1055";
  require(process.env.PRELOAD);
  const after = [http.globalAgent.options, https.globalAgent.options].map((o) => {
    const { proxyEnv, ...rest } = o;
    if (proxyEnv.https_proxy !== "http://127.0.0.1:1055" || proxyEnv.no_proxy !== "") throw new Error("proxyEnv " + JSON.stringify(proxyEnv));
    return JSON.stringify(rest);
  });
  if (before.join() !== after.join()) throw new Error("options changed: " + before + " -> " + after);
  console.log(after.join(" "));
' 2>&1)" || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "::error::the preload changed the agent options: $out"
  status=1
else
  echo "OK: agent options are Node's defaults plus the proxy: $out"
fi

# Routing: with NO_PROXY=*, a request to Vault still goes to the proxy. The
# fake proxy records the CONNECT target and refuses it; nothing leaves the host.
rc=0
out="$(env -i PATH="$PATH" PRELOAD="$preload" NO_PROXY='*' no_proxy='*' node -e '
  const net = require("node:net");
  const server = net.createServer((s) => {
    s.once("data", (d) => {
      console.log(String(d).split("\r\n")[0]);
      s.end("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n");
      server.close();
    });
  });
  server.listen(0, "127.0.0.1", () => {
    process.env.VAULT_SECRETS_PROXY_URL = "http://127.0.0.1:" + server.address().port;
    require(process.env.PRELOAD);
    require("node:https")
      .get("https://vault-ospo.eng-svc.aws.tenstorrent.com/v1/sys/health", () => {})
      .on("error", () => {});
  });
  setTimeout(() => { console.log("no request at the proxy"); process.exit(1); }, 5000).unref();
' 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] || [ "$out" != 'CONNECT vault-ospo.eng-svc.aws.tenstorrent.com:443 HTTP/1.1' ]; then
  echo "::error::the Vault request did not go to the proxy: $out"
  status=1
else
  echo "OK: with NO_PROXY=*, the Vault request goes to the proxy ($out)"
fi

exit "$status"
