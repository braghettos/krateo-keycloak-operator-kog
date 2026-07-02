set -e
D=/Users/diegobraga/krateo/keycloak/demo-mfa-stepup
CA=$D/certs/ca.crt
curlk() { curl -s --resolve keycloak:8443:127.0.0.1 --cacert "$CA" "$@"; }
AT=$(curlk https://keycloak:8443/realms/master/protocol/openid-connect/token \
  -d grant_type=password -d client_id=admin-cli -d username=admin -d password=admin | jq -r .access_token)
echo "admin token: ${AT:0:12}..."
AID=$(curlk -H "Authorization: Bearer $AT" "https://keycloak:8443/admin/realms/cmp/users?username=alice" | jq -r '.[0].id')
if [ "$AID" != "null" ] && [ -n "$AID" ]; then
  curlk -H "Authorization: Bearer $AT" -X DELETE "https://keycloak:8443/admin/realms/cmp/users/$AID"; echo "deleted old alice ($AID)"
fi
SECRET="CMPDEMOTOTPSECRET123"
echo "TOTP secret: $SECRET"
curlk -H "Authorization: Bearer $AT" -H "Content-Type: application/json" -X POST "https://keycloak:8443/admin/realms/cmp/users" -d "{
  \"username\":\"alice\",\"enabled\":true,\"email\":\"alice@example.com\",\"emailVerified\":true,
  \"firstName\":\"Alice\",\"lastName\":\"Admin\",
  \"credentials\":[
    {\"type\":\"password\",\"value\":\"alice\",\"temporary\":false},
    {\"type\":\"otp\",\"userLabel\":\"totp\",\"secretData\":\"{\\\"value\\\":\\\"$SECRET\\\"}\",\"credentialData\":\"{\\\"subType\\\":\\\"totp\\\",\\\"digits\\\":6,\\\"period\\\":30,\\\"algorithm\\\":\\\"HmacSHA1\\\"}\"}
  ],
  \"groups\":[\"/cmp-admins\"]
}"
NID=$(curlk -H "Authorization: Bearer $AT" "https://keycloak:8443/admin/realms/cmp/users?username=alice" | jq -r '.[0].id')
echo "new alice id: $NID"
echo "credentials: $(curlk -H "Authorization: Bearer $AT" "https://keycloak:8443/admin/realms/cmp/users/$NID/credentials" | jq -r '[.[].type]|join(",")')"
echo "groups: $(curlk -H "Authorization: Bearer $AT" "https://keycloak:8443/admin/realms/cmp/users/$NID/groups" | jq -r '[.[].name]|join(",")')"
