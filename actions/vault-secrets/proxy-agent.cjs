'use strict';

// Loaded with --require only into the "Read from Vault" step, and only in
// network-mode userspace. Got (the HTTP library of the pinned
// hashicorp/vault-action) uses Node's global agents. vault-action has no proxy
// input, so this gives the global agents the Tailscale loopback proxy. Since
// release 1.1 the step uses method token and makes no GitHub OIDC request, so
// every request of this step goes to Vault. An inherited NO_PROXY cannot
// bypass the proxy: the agents read only proxyEnv below.
const http = require('node:http');
const https = require('node:https');
const [major, minor] = process.versions.node.split('.').map(Number);
if (major < 24 || (major === 24 && minor < 5)) {
  throw new Error('vault-secrets userspace mode requires Node 24.5 or newer in the Actions runner');
}
const proxy = process.env.VAULT_SECRETS_PROXY_URL;
// The same rule as prepare.sh, login.sh and read-token.sh: loopback, port 1 to 65535.
const port = /^http:\/\/127\.0\.0\.1:([1-9]\d{0,4})$/.exec(proxy || '');
if (!port || Number(port[1]) > 65535) {
  throw new Error('vault-secrets userspace proxy setting is missing or invalid');
}
// Copy the options of Node's own global agents and add only the proxy. The
// preload sets no timeout of its own: the agents keep the same options as in
// network-mode kernel, and the action's watchdog (vault-timeout-seconds)
// stays the time limit of the step.
const proxyEnv = { http_proxy: proxy, https_proxy: proxy, no_proxy: '', NO_PROXY: '' };
http.globalAgent = new http.Agent({ ...http.globalAgent.options, proxyEnv });
https.globalAgent = new https.Agent({ ...https.globalAgent.options, proxyEnv });
