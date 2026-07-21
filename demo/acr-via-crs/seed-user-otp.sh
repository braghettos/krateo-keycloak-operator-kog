#!/usr/bin/env bash
# Seed a test user with a password AND a registered TOTP credential in the
# realm the sample manages (`mfa-demo`). The LoA-2 leg of the CR-built ladder
# is OTP, so a user without a TOTP credential can never reach acr=2.
#
# TOTP registration is a per-user RUNTIME act (the user scans a QR), NOT
# config-as-code — so it is intentionally OUTSIDE the CR surface and seeded
# here via Keycloak's admin API (kcadm-equivalent), the same way
# demo/mfa-stepup/scripts/30-seed-user-otp.sh does.
#
# ENV: KC_URL (default http://localhost:8080), REALM (mfa-demo),
#      ADMIN/ADMIN_PASS (admin/admin), USER_NAME (alice), USER_PASS (alice),
#      TOTP_SECRET (required, raw secret — feed the SAME value to apply-and-mint.sh).
set -euo pipefail

KC_URL="${KC_URL:-http://localhost:8080}"; KC_URL="${KC_URL%/}"
REALM="${REALM:-mfa-demo}"
ADMIN="${ADMIN:-admin}"; ADMIN_PASS="${ADMIN_PASS:-admin}"
USER_NAME="${USER_NAME:-alice}"; USER_PASS="${USER_PASS:-alice}"
: "${TOTP_SECRET:?set TOTP_SECRET to a raw secret (reuse it in apply-and-mint.sh)}"

command -v jq >/dev/null || { echo "jq required"; exit 2; }
curlk() { curl -sk "$@"; }

AT="$(curlk "$KC_URL/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli \
  -d username="$ADMIN" -d password="$ADMIN_PASS" | jq -r .access_token)"
[ -n "$AT" ] && [ "$AT" != "null" ] || { echo "FATAL: admin auth failed"; exit 1; }
H=(-H "Authorization: Bearer $AT")

OLD="$(curlk "${H[@]}" "$KC_URL/admin/realms/$REALM/users?username=$USER_NAME" | jq -r '.[0].id // empty')"
if [ -n "$OLD" ]; then
  curlk "${H[@]}" -X DELETE "$KC_URL/admin/realms/$REALM/users/$OLD"; echo "deleted old $USER_NAME ($OLD)"
fi

curlk "${H[@]}" -H "Content-Type: application/json" -X POST "$KC_URL/admin/realms/$REALM/users" -d @- <<JSON
{
  "username": "$USER_NAME", "enabled": true, "emailVerified": true,
  "credentials": [
    {"type": "password", "value": "$USER_PASS", "temporary": false},
    {"type": "otp", "userLabel": "totp",
     "secretData": "{\"value\":\"$TOTP_SECRET\"}",
     "credentialData": "{\"subType\":\"totp\",\"digits\":6,\"period\":30,\"algorithm\":\"HmacSHA1\"}"}
  ]
}
JSON

NID="$(curlk "${H[@]}" "$KC_URL/admin/realms/$REALM/users?username=$USER_NAME" | jq -r '.[0].id')"
echo "seeded $USER_NAME ($NID) with credentials: $(curlk "${H[@]}" "$KC_URL/admin/realms/$REALM/users/$NID/credentials" | jq -r '[.[].type]|join(",")')"
