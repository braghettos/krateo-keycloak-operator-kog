#!/usr/bin/env bash
# ===========================================================================
# acr=2, traced through the CRs THIS PR ships.
#
# The existing demo/mfa-stepup builds the Keycloak LoA ladder IMPERATIVELY
# (kcadm scripts 31/32) against client `kubernetes` with acr_values=2. That
# proves the admission gate, but it does NOT exercise the
# KeycloakAuthenticationExecution CRs.
#
# THIS script closes that gap: it `kubectl apply`s the SAME sample this PR
# ships (samples/20-authentication-mfa.yaml — flow `browser-mfa`, its
# executions/subflows as CRs, client `acr-app` with acr.loa.map gold=2), lets
# the Krateo control plane reconcile the ladder into Keycloak, then mints a
# token with the MATCHING client+acr_values (`acr-app`, acr_values=gold) and
# asserts the issued token carries acr=2.
#
# ---------------------------------------------------------------------------
# PRECONDITIONS (this needs a LIVE cluster + control plane — not simulated):
#   1. A Kubernetes cluster with the Krateo control plane AND this chart
#      installed, with snowplow + authn wired into the rdc deployment (see
#      docs/ARCHITECTURE.md "Deployment prerequisites"). The
#      KeycloakAuthenticationExecution RestDefinition + its RESTActions must be
#      Ready:
#        kubectl -n "$NS" wait --for=condition=Ready restdefinition --all --timeout=5m
#   2. A Keycloak reachable BOTH from the controllers (in-cluster URL, already
#      in values.yaml) AND from this script (KC_URL below, for token minting).
#   3. The keycloak-admin token Secret present (ESO-managed or manual) so the
#      Configuration CRs in samples/00-configurations.yaml can authenticate.
#   4. A test user with a password AND a registered TOTP credential in the
#      `mfa-demo` realm (the ladder's LoA-2 leg is OTP). Seed one with:
#        USER_NAME=alice USER_PASS=alice TOTP_SECRET=... bash "$(dirname "$0")/seed-user-otp.sh"
#      (kcadm/admin-API seeding — TOTP registration is a per-user runtime act,
#      not config-as-code, so it is intentionally out of the CR surface.)
#
# ENV (override as needed):
#   NS           namespace the CRs live in            (default krateo-system)
#   KC_URL       Keycloak base URL reachable HERE      (default http://localhost:8080)
#   REALM        realm alias (matches the sample)      (default mfa-demo)
#   CLIENT       client id (matches the sample)        (default acr-app)
#   CLIENT_SECRET  confidential client secret          (required; acr-app is not public)
#   ACR_VALUES   requested ACR (matches acr.loa.map)   (default gold)
#   USER_NAME/PASS  test user credentials              (default alice / alice)
#   TOTP_SECRET  raw TOTP secret seeded for USER        (required)
#   REDIRECT_URI a redirect URI registered on CLIENT   (default http://localhost:8000)
#   APPLY        set to 0 to skip the kubectl apply/wait (mint only) (default 1)
#
# Exit 0 only if the token minted through the CR-built ladder carries acr=2.
# ===========================================================================
set -euo pipefail

NS="${NS:-krateo-system}"
KC_URL="${KC_URL:-http://localhost:8080}"; KC_URL="${KC_URL%/}"
REALM="${REALM:-mfa-demo}"
CLIENT="${CLIENT:-acr-app}"
ACR_VALUES="${ACR_VALUES:-gold}"
USER_NAME="${USER_NAME:-alice}"
PASS="${PASS:-alice}"
REDIRECT_URI="${REDIRECT_URI:-http://localhost:8000}"
APPLY="${APPLY:-1}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

need() { command -v "$1" >/dev/null || { echo "FATAL: '$1' is required"; exit 2; }; }
need curl; need jq; need python3
[ -n "${CLIENT_SECRET:-}" ] || { echo "FATAL: CLIENT_SECRET is required ($CLIENT is a confidential client)"; exit 2; }
[ -n "${TOTP_SECRET:-}" ]   || { echo "FATAL: TOTP_SECRET is required (raw secret seeded for $USER_NAME)"; exit 2; }

# ---------------------------------------------------------------------------
# 1. Apply the sample CRs and let the control plane reconcile the ladder.
# ---------------------------------------------------------------------------
if [ "$APPLY" = "1" ]; then
  need kubectl
  echo "== applying the sample CRs (Configurations + MFA ladder) into $NS =="
  kubectl apply -n "$NS" -f "$ROOT/samples/00-configurations.yaml"
  kubectl apply -n "$NS" -f "$ROOT/samples/20-authentication-mfa.yaml"

  echo "== waiting for the KeycloakAuthenticationExecution CRs to reconcile =="
  # The control plane (oasgen + rdc + snowplow) drives each CR to Ready as its
  # execution/subflow lands in the flow. This is the LIVE reconcile step.
  if ! kubectl wait -n "$NS" --for=condition=Ready \
        keycloakauthenticationexecution --all --timeout="${WAIT_TIMEOUT:-5m}"; then
    echo "FATAL: executions did not reach Ready — inspect:"
    echo "  kubectl -n $NS get keycloakauthenticationexecution"
    echo "  kubectl -n $NS describe keycloakauthenticationexecution"
    exit 1
  fi

  # The sample leaves browserFlow UNBOUND so a first apply cannot race the
  # flow's creation. Now that the ladder has converged, bind it as the realm's
  # browser flow via the CR (GitOps, not kcadm).
  echo "== binding browser-mfa as the realm's browser flow (via CR patch) =="
  kubectl patch -n "$NS" keycloakrealm mfa-demo --type merge \
    -p '{"spec":{"browserFlow":"browser-mfa"}}'
  kubectl wait -n "$NS" --for=condition=Ready keycloakrealm/mfa-demo --timeout="${WAIT_TIMEOUT:-5m}"
else
  echo "== APPLY=0: skipping kubectl apply/wait, minting against the existing ladder =="
fi

# ---------------------------------------------------------------------------
# 2. Mint a token through the CR-built ladder: acr_values=gold on client acr-app.
#    Interactive auth-code flow (browser step-up carries auth_time + real acr).
# ---------------------------------------------------------------------------
echo "== minting: client=$CLIENT acr_values=$ACR_VALUES realm=$REALM =="
BASE="$KC_URL/realms/$REALM/protocol/openid-connect"
CJ="$(mktemp)"; trap 'rm -f "$CJ"' EXIT
curlk() { curl -sk -c "$CJ" -b "$CJ" "$@"; }

totp() { python3 - "$1" <<'PY'
import sys, hmac, hashlib, struct, time
key = sys.argv[1].encode()
msg = struct.pack(">Q", int(time.time()) // 30)
h = hmac.new(key, msg, hashlib.sha1).digest()
o = h[-1] & 0x0f
print("%06d" % ((struct.unpack(">I", h[o:o+4])[0] & 0x7fffffff) % 1000000))
PY
}
form_action() { grep -oiE 'action="[^"]+"' | head -1 | sed -E 's/action="([^"]+)"/\1/' | sed 's/\&amp;/\&/g'; }

AUTHZ="$BASE/auth?client_id=$CLIENT&response_type=code&scope=openid&redirect_uri=$REDIRECT_URI&state=st1&nonce=no1&acr_values=$ACR_VALUES"
ACTION="$(curlk "$AUTHZ" | form_action)"
[ -n "$ACTION" ] || { echo "FATAL: no login form (is $CLIENT's redirect_uri $REDIRECT_URI registered?)"; exit 1; }

# password (LoA 1)
R1="$(curlk -i -X POST "$ACTION" --data-urlencode "username=$USER_NAME" --data-urlencode "password=$PASS" --data-urlencode "credentialId=")"
OTP_ACTION="$(printf '%s' "$R1" | form_action)"
[ -n "$OTP_ACTION" ] || { echo "FATAL: no OTP form after password — did the LoA-2 leg trigger? (acr_values=$ACR_VALUES must map to level 2)"; exit 1; }

# TOTP (LoA 2 step-up)
CODE="$(totp "$TOTP_SECRET")"
echo "   step-up: computed TOTP $CODE"
R2="$(curlk -i -X POST "$OTP_ACTION" --data-urlencode "otp=$CODE")"
LOC="$(printf '%s' "$R2" | grep -i '^location:' | head -1 | tr -d '\r')"
CODE_PARAM="$(printf '%s' "$LOC" | grep -oE 'code=[^&]+' | head -1 | cut -d= -f2 || true)"
[ -n "$CODE_PARAM" ] || { echo "FATAL: no auth code — OTP rejected (check TOTP_SECRET / clock skew)"; exit 1; }

# exchange code -> id_token (confidential client => client_secret)
ID_TOKEN="$(curlk "$BASE/token" \
  -d grant_type=authorization_code -d client_id="$CLIENT" -d client_secret="$CLIENT_SECRET" \
  -d code="$CODE_PARAM" -d redirect_uri="$REDIRECT_URI" | jq -r .id_token)"
[ -n "$ID_TOKEN" ] && [ "$ID_TOKEN" != "null" ] || { echo "FATAL: token exchange failed (client_secret?)"; exit 1; }

ACR="$(printf '%s' "$ID_TOKEN" | cut -d. -f2 | python3 -c '
import sys, base64, json
p = sys.stdin.read().strip(); p += "=" * (-len(p) % 4)
d = json.loads(base64.urlsafe_b64decode(p))
print(json.dumps({k: d.get(k) for k in ("acr", "aud", "preferred_username", "auth_time")}))
print(d.get("acr"), file=sys.stderr)
' 2>/tmp/acr_val.txt)"
echo "== id_token claims: $ACR"
ACR_CLAIM="$(cat /tmp/acr_val.txt)"; rm -f /tmp/acr_val.txt

if [ "$ACR_CLAIM" = "2" ]; then
  echo "PASS: token minted through the CR-built ladder carries acr=2"
  exit 0
fi
echo "FAIL: expected acr=2, got acr=$ACR_CLAIM"
exit 1
