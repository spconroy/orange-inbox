#!/usr/bin/env bash
# orange-inbox: idempotent setup + deploy.
#
# Creates (or finds) the D1 database, R2 buckets, and KV namespace this app
# needs, patches the binding IDs into wrangler.jsonc, applies migrations, and
# deploys both Workers. Re-runnable: every step looks up existing resources
# before creating, and synchronizes the managed D1 and KV binding IDs.
#
# Usage:  ./scripts/setup.sh [--help]
# Env:    CLOUDFLARE_ACCOUNT_ID  Required if your wrangler login has access to
#                                multiple accounts. Forwarded to wrangler.

set -euo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'HELP'
orange-inbox setup + deploy.

Creates Cloudflare resources, applies migrations, deploys both Workers.
Idempotent — re-running on an existing deploy skips creation and just
re-applies migrations + redeploys.

Resources created (one each, free-tier-eligible):
  • D1 database         "orange-inbox"
  • R2 bucket           "orange-inbox-raw"
  • R2 bucket           "orange-inbox-attachments"
  • KV namespace        "DRAFTS"
  • Worker              "orange-inbox-web"      (Next.js via OpenNext)
  • Worker              "orange-inbox-email"    (inbound MIME parser)
  • Secrets             INTERNAL_SECRET (both workers), VAPID_PRIVATE_KEY (web)

Two manual steps after this script finishes — see the banner at the end.

Environment:
  CLOUDFLARE_ACCOUNT_ID   Set this if your wrangler login has access to
                          multiple accounts; otherwise wrangler picks one.

Usage:
  ./scripts/setup.sh           # first-time setup or update
  ./scripts/setup.sh --help    # this message
HELP
  exit 0
fi

cd "$(cd "$(dirname "$0")"/.. && pwd)"
ROOT=$(pwd)

# ─── output helpers ─────────────────────────────────────────────────────────
log() { printf '\033[1;33m▸\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; }

uuid_re='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
hex32_re='[0-9a-f]{32}'

# We run wrangler from web/ so it picks up the locally-installed binary and
# the project's compatibility flags. Path is anchored to $ROOT so cd's compose.
wr() { (cd "$ROOT/web" && npx --yes wrangler "$@"); }

# ─── preflight ──────────────────────────────────────────────────────────────
command -v node >/dev/null 2>&1 || { err "node not found in PATH"; exit 1; }
command -v npm  >/dev/null 2>&1 || { err "npm not found in PATH"; exit 1; }

# Node 20.9+ required for OpenNext + wrangler. Older versions silently
# break OpenNext's bundle generation in confusing ways, so fail hard here.
NODE_MAJOR=$(node -p "process.versions.node.split('.')[0]")
NODE_MINOR=$(node -p "process.versions.node.split('.')[1]")
if [ "$NODE_MAJOR" -lt 20 ] || { [ "$NODE_MAJOR" -eq 20 ] && [ "$NODE_MINOR" -lt 9 ]; }; then
  err "Node 20.9+ required (found $(node -v)). Install via nvm: nvm install 20 && nvm use 20"
  exit 1
fi

log "Installing web dependencies"
(cd "$ROOT/web" && npm install --silent)
log "Installing email-worker dependencies"
(cd "$ROOT/email-worker" && npm install --silent)

if ! wr whoami >/dev/null 2>&1; then
  err "wrangler is not authenticated. Run: cd web && npx wrangler login"
  exit 1
fi

# Account identification. We forward CLOUDFLARE_ACCOUNT_ID to all wrangler
# invocations when set; this is the recommended fix for "multiple accounts
# accessible to one OAuth token" — wrangler otherwise picks the first one
# silently, which is fine for single-account users but a surprise if you
# happen to have a second team account on the same login.
WHOAMI=$(wr whoami 2>&1 || true)
ACCOUNT_LINES=$(printf '%s' "$WHOAMI" | grep -cE "│\\s+[0-9a-f]{32}\\s+│" || true)
if [ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
  export CLOUDFLARE_ACCOUNT_ID
  ok "Using Cloudflare account: $CLOUDFLARE_ACCOUNT_ID (from CLOUDFLARE_ACCOUNT_ID)"
elif [ "${ACCOUNT_LINES:-0}" -gt 1 ]; then
  err "Your wrangler login has access to multiple Cloudflare accounts."
  err "Set CLOUDFLARE_ACCOUNT_ID to pick one, e.g.:"
  err "  CLOUDFLARE_ACCOUNT_ID=<32-char-id> ./scripts/setup.sh"
  err ""
  printf '%s\n' "$WHOAMI" >&2
  exit 1
else
  ACCOUNT_NAME=$(printf '%s' "$WHOAMI" \
    | awk -F'│' '/│ +[0-9a-f]{32} +│/ { gsub(/^ +| +$/, "", $2); print $2; exit }')
  ok "Authenticated to Cloudflare${ACCOUNT_NAME:+ ($ACCOUNT_NAME)}"
fi

# ─── D1 ────────────────────────────────────────────────────────────────────
log "D1: ensuring database 'orange-inbox'"
D1_ID=$(wr d1 list 2>&1 | grep -E '\borange-inbox\b' | grep -oE "$uuid_re" | head -1 || true)
if [ -z "$D1_ID" ]; then
  D1_ID=$(wr d1 create orange-inbox 2>&1 | grep -oE "$uuid_re" | head -1)
  ok "Created D1: $D1_ID"
else
  ok "Found existing D1: $D1_ID"
fi

# ─── R2 ────────────────────────────────────────────────────────────────────
for bucket in orange-inbox-raw orange-inbox-attachments; do
  log "R2: ensuring bucket '$bucket'"
  if wr r2 bucket info "$bucket" >/dev/null 2>&1; then
    ok "Bucket exists: $bucket"
  else
    wr r2 bucket create "$bucket" >/dev/null 2>&1 || true
    ok "Created R2 bucket: $bucket"
  fi
done

# ─── KV ────────────────────────────────────────────────────────────────────
log "KV: ensuring namespace 'DRAFTS'"
KV_LIST=$(wr kv namespace list 2>/dev/null || echo "[]")
KV_ID=$(printf '%s' "$KV_LIST" \
  | tr -d '\n' \
  | grep -oE "\\{[^}]*\"title\":[^}]*DRAFTS[^}]*\\}" \
  | grep -oE "\"id\":\\s*\"$hex32_re\"" \
  | grep -oE "$hex32_re" \
  | head -1 || true)
if [ -z "$KV_ID" ]; then
  KV_ID=$(wr kv namespace create DRAFTS 2>&1 | grep -oE "$hex32_re" | head -1)
  ok "Created KV: $KV_ID"
else
  ok "Found existing KV: $KV_ID"
fi

# ─── patch wrangler.jsonc ───────────────────────────────────────────────────
log "Patching binding IDs into wrangler.jsonc"
# Update existing IDs as well as placeholders, scoped to the managed binding.
node - "$ROOT" "$D1_ID" "$KV_ID" <<'NODE'
const fs = require('node:fs');
const [root, d1, kv] = process.argv.slice(2);
if (!/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(d1) ||
    !/^[0-9a-f]{32}$/.test(kv)) {
  throw new Error('Invalid resource IDs returned by Wrangler');
}
const updates = [
  ['web/wrangler.jsonc', [['DB', 'database_id', d1], ['DRAFTS', 'id', kv]]],
  ['email-worker/wrangler.jsonc', [['DB', 'database_id', d1]]],
].map(([file, bindings]) => {
  const path = `${root}/${file}`;
  let text = fs.readFileSync(path, 'utf8');
  for (const [binding, key, value] of bindings) {
    let count = 0;
    text = text.replace(/\{[^{}]*\}/g, object => {
      if (!new RegExp(`"binding"\\s*:\\s*"${binding}"`).test(object)) return object;
      const field = new RegExp(`("${key}"\\s*:\\s*")[^"]*(")`, 'g');
      return object.replace(field, (_, prefix, suffix) => {
        count++;
        return prefix + value + suffix;
      });
    });
    if (count !== 1) throw new Error(`Expected one ${binding}.${key} in ${file}, found ${count}`);
  }
  return [path, text];
});
for (const [path, text] of updates) fs.writeFileSync(path, text);
NODE

# ─── migrations ────────────────────────────────────────────────────────────
log "Applying D1 migrations to remote database"
wr d1 migrations apply orange-inbox --remote
ok "Migrations applied"

# ─── deploy ─────────────────────────────────────────────────────────────────
# Stream output and retain web output for the URL health check. With pipefail,
# a failed deployment exits with its error visible instead of hiding it in a variable.
DEPLOY_LOG=$(mktemp)
trap 'rm -f "$DEPLOY_LOG"' EXIT

# The email Worker's WEB service binding requires the web Worker to exist first.
log "Deploying web (Next.js build via OpenNext — takes a couple minutes)"
(cd "$ROOT/web" && npm run deploy) 2>&1 | tee "$DEPLOY_LOG"
WEB_DEPLOY=$(cat "$DEPLOY_LOG")

log "Deploying email-worker"
(cd "$ROOT/email-worker" && npx --yes wrangler deploy) 2>&1 | tee "$DEPLOY_LOG"

# Wrangler prints the deployed URL on a line like:
#   "https://orange-inbox-web.<subdomain>.workers.dev"
WEB_URL=$(printf '%s' "$WEB_DEPLOY" | grep -oE 'https://[a-z0-9.-]+\.workers\.dev' | head -1 || true)

# ─── INTERNAL_SECRET ────────────────────────────────────────────────────────
# Shared between the two workers — gates /api/internal/dispatch-scheduled.
# The placeholder in wrangler.jsonc is a public var; a secret with the same
# name overrides it at runtime. Must run after deploy because `secret put`
# requires the worker to exist.
log "Ensuring INTERNAL_SECRET is set on both workers"
secret_exists() {
  (cd "$1" && npx --yes wrangler secret list 2>/dev/null) \
    | grep -q INTERNAL_SECRET
}
if secret_exists "$ROOT/web" && secret_exists "$ROOT/email-worker"; then
  ok "INTERNAL_SECRET already set on both workers"
else
  command -v openssl >/dev/null 2>&1 || { err "openssl not found in PATH"; exit 1; }
  SECRET=$(openssl rand -hex 32)
  printf '%s' "$SECRET" | (cd "$ROOT/web"          && npx --yes wrangler secret put INTERNAL_SECRET) >/dev/null
  printf '%s' "$SECRET" | (cd "$ROOT/email-worker" && npx --yes wrangler secret put INTERNAL_SECRET) >/dev/null
  unset SECRET
  ok "Set INTERNAL_SECRET on both workers"
fi

# ─── VAPID_PRIVATE_KEY (Web Push) ──────────────────────────────────────────
# Signs the JWT on /api/internal/notify-new-message. Public key + subject
# live in web/wrangler.jsonc vars. Idempotent — only generates if missing.
log "Ensuring VAPID_PRIVATE_KEY is set on web worker"
vapid_exists() {
  (cd "$ROOT/web" && npx --yes wrangler secret list 2>/dev/null) \
    | grep -q VAPID_PRIVATE_KEY
}
if vapid_exists; then
  ok "VAPID_PRIVATE_KEY already set"
else
  log "Generating VAPID keypair (run \`pnpm vapid\` to print again)"
  VAPID_OUTPUT=$(cd "$ROOT/web" && node scripts/generate-vapid.mjs)
  VAPID_PUB=$(printf '%s\n' "$VAPID_OUTPUT" | grep '^VAPID_PUBLIC_KEY=' | cut -d= -f2)
  VAPID_PRIV=$(printf '%s\n' "$VAPID_OUTPUT" | grep '^VAPID_PRIVATE_KEY=' | cut -d= -f2)
  printf '%s' "$VAPID_PRIV" | (cd "$ROOT/web" && npx --yes wrangler secret put VAPID_PRIVATE_KEY) >/dev/null
  unset VAPID_PRIV VAPID_OUTPUT
  ok "Set VAPID_PRIVATE_KEY (private). Public key for wrangler.jsonc vars: $VAPID_PUB"
fi

# ─── post-deploy health check ──────────────────────────────────────────────
# Best-effort: hit the deployed worker URL and confirm it responds. We expect
# either 200 (no Access in front yet) or 302 (Access redirecting to login),
# both of which mean the worker booted and is serving requests. A 5xx here
# usually means a binding ID didn't get patched — actionable signal.
if [ -n "$WEB_URL" ]; then
  log "Health check: $WEB_URL"
  if command -v curl >/dev/null 2>&1; then
    HEALTH_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$WEB_URL" || echo "000")
    case "$HEALTH_CODE" in
      2*|3*)
        ok "Worker is up (HTTP $HEALTH_CODE)"
        ;;
      000)
        err "Worker did not respond within 15s ($WEB_URL). Check 'npx wrangler tail' for errors."
        ;;
      *)
        err "Worker returned HTTP $HEALTH_CODE — likely a wrangler.jsonc placeholder wasn't patched."
        err "  Run: grep REPLACE_WITH web/wrangler.jsonc email-worker/wrangler.jsonc"
        ;;
    esac
  else
    log "(curl not installed; skipping health check)"
  fi
fi

# ─── done ───────────────────────────────────────────────────────────────────
cat <<BANNER

────────────────────────────────────────────
✓ Deployment complete.${WEB_URL:+

Worker URL: $WEB_URL}

Two manual steps to make it usable:

1. Cloudflare Access (login):
   Zero Trust → Access → Applications → Add a self-hosted application
   targeting your orange-inbox-web Worker URL. Add an Access policy
   (e.g. "Emails ending with @yourdomain.com"). Without Access in
   front, the app shows "Sign in required".

   Sign into the app once to create your user, then grant your account
   admin access. In Cloudflare → D1 → orange-inbox → Console, run:
     UPDATE users SET is_admin = 1 WHERE email = 'your-login-email';
   Replace your-login-email with your sign-in email in lowercase, then
   refresh the app. New users are not admins by default.

2. Email Routing (mail flow):
   In the Cloudflare dashboard, enable Email Routing for any domain
   you want to receive mail on, and add a rule sending mail to the
   orange-inbox-email Worker. Then sign into the app as an admin and add
   the same domain in Settings → Mail domains → Add domain
   (/inbox/settings#mail-domains).

For local development:
   echo 'DEV_USER_EMAIL=you@yourdomain.com' > web/.dev.vars
   echo 'INTERNAL_SECRET=dev-only-secret'   >> web/.dev.vars
   echo 'INTERNAL_SECRET=dev-only-secret'   > email-worker/.dev.vars
   cd web && npm run dev
────────────────────────────────────────────
BANNER
