#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

for key in COIL_ACCOUNT_ID COIL_DOMAIN COIL_ACCESS_TEAM COIL_ACCESS_AUD; do
  [ -n "${!key:-}" ] || { echo "missing build variable: $key" >&2; exit 2; }
done
export CLOUDFLARE_ACCOUNT_ID="$COIL_ACCOUNT_ID"
# Cloudflare build containers do not provide Docker bridge networking.
export WRANGLER_CI_OVERRIDE_NETWORK_MODE_HOST=1

base_tag=nix-cf-proof:3f60b582
images=$(npx wrangler containers images list)
if ! printf '%s\n' "$images" | grep -Eq '^nix-cf-proof[[:space:]]+3f60b582[[:space:]]*$'; then
  docker build --network=host --platform linux/amd64 -f computer/Dockerfile.base -t "$base_tag" computer
  npx wrangler containers push "$base_tag"
fi
export NIX_IMAGE="registry.cloudflare.com/$COIL_ACCOUNT_ID/$base_tag"

umask 077
cp deploy/example.conf deploy/cloudflare.conf
node --input-type=module <<'NODE'
import { readFileSync, writeFileSync } from 'node:fs';

const path = 'deploy/cloudflare.conf';
const keys = new Set(['COIL_ACCOUNT_ID', 'COIL_DOMAIN', 'COIL_ACCESS_TEAM', 'COIL_ACCESS_AUD', 'NIX_IMAGE']);
const quote = (value) => `'${value.replaceAll("'", "'\\''")}'`;
const text = readFileSync(path, 'utf8').replace(/^([A-Z_]+)=.*$/gm, (line, key) =>
  keys.has(key) ? `${key}=${quote(process.env[key])}` : line,
);
writeFileSync(path, text);
NODE

node --input-type=module <<'NODE'
import { execFileSync } from 'node:child_process';

const credentials = JSON.parse(execFileSync('npx', [
  'wrangler', 'containers', 'registries', 'credentials', 'registry.cloudflare.com',
  '--pull', '--expiration-minutes', '30', '--json',
], { encoding: 'utf8' }));
execFileSync('docker', ['login', 'registry.cloudflare.com', '--username', credentials.username, '--password-stdin'], {
  input: credentials.password,
  stdio: ['pipe', 'inherit', 'inherit'],
});
NODE

bun run ship -- deploy/cloudflare.conf
