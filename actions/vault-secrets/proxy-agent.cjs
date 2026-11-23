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
if (!/^http:\/\/127\.0\.0\.1:\d+$/.test(proxy || '')) {
  throw new Error('vault-secrets userspace proxy setting is missing or invalid');
}
const options = {
  keepAlive: true,
  scheduling: 'lifo',
  timeout: 5000,
  proxyEnv: { http_proxy: proxy, https_proxy: proxy, no_proxy: '', NO_PROXY: '' },
};
http.globalAgent = new http.Agent(options);
https.globalAgent = new https.Agent(options);
