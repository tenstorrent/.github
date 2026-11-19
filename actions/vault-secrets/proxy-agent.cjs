'use strict';

// Got (the pinned Vault client's HTTP library) uses Node's global agents.
// @actions/http-client (GitHub OIDC) selects its own agent when the runner has
// an outbound proxy. Keep its environment untouched, and bypass the Vault
// proxy for the OIDC host when it falls back to a global agent on other runners.
const http = require('node:http');
const https = require('node:https');
const [major, minor] = process.versions.node.split('.').map(Number);
if (major < 24 || (major === 24 && minor < 5)) {
  throw new Error('vault-secrets userspace mode requires Node 24.5 or newer in the Actions runner');
}
const proxy = process.env.VAULT_SECRETS_PROXY_URL;
const oidcHost = process.env.VAULT_SECRETS_OIDC_HOST;
if (!/^http:\/\/127\.0\.0\.1:\d+$/.test(proxy || '') || !/^[A-Za-z0-9.-]+$/.test(oidcHost || '')) {
  throw new Error('vault-secrets userspace proxy settings are missing or invalid');
}
const options = {
  keepAlive: true,
  scheduling: 'lifo',
  timeout: 5000,
  proxyEnv: { http_proxy: proxy, https_proxy: proxy, no_proxy: oidcHost },
};
http.globalAgent = new http.Agent(options);
https.globalAgent = new https.Agent(options);
