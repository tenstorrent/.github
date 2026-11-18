#!/usr/bin/env bash
# Waits until Vault answers its health endpoint. Reads VAULT_URL from env.
set -euo pipefail

curl_args=(-fsS --max-time 5 -o /dev/null)
if [ -n "${VAULT_PROXY:-}" ]; then
  # Explicitly defeat inherited NO_PROXY rules for the private Vault endpoint.
  curl_args+=(--proxy "$VAULT_PROXY" --noproxy '')
fi
health="${VAULT_URL}/v1/sys/health?standbyok=true&uninitcode=204&sealedcode=204"
for _ in 1 2 3 4 5 6; do
  if curl "${curl_args[@]}" "$health"; then
    echo "Vault ${VAULT_URL} is reachable."
    exit 0
  fi
  sleep 2
done

printf '::error title=vault-secrets::%s\n' "Vault ${VAULT_URL} is not reachable. Likely causes: the runner is not on the tailnet (join-tailnet is false, or the job joined with a tag that has no route to Vault); the Tailscale join failed (see the step above); vault-url is wrong; Vault is down."
exit 1
