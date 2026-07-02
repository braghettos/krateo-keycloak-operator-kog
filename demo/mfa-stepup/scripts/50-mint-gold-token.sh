set -e
D=/Users/diegobraga/krateo/keycloak/demo-mfa-stepup
CA=$D/certs/ca.crt
CJ=$(mktemp)
curlk() { curl -s --resolve keycloak:8443:127.0.0.1 --cacert "$CA" "$@"; }
totp() { python3 - "$1" <<'PY'
import sys,hmac,hashlib,struct,time
key=sys.argv[1].encode()
t=int(time.time())//30
msg=struct.pack(">Q",t)
h=hmac.new(key,msg,hashlib.sha1).digest()
o=h[-1]&0x0f
code=(struct.unpack(">I",h[o:o+4])[0]&0x7fffffff)%1000000
print("%06d"%code)
PY
}
BASE="https://keycloak:8443/realms/cmp/protocol/openid-connect"
REDIR="http://localhost:8000"
AUTHZ="$BASE/auth?client_id=kubernetes&response_type=code&scope=openid&redirect_uri=$REDIR&state=st1&nonce=no1&acr_values=2"
# 1) login page -> form action
HTML=$(curlk -c "$CJ" -b "$CJ" "$AUTHZ")
ACTION=$(echo "$HTML" | grep -oiE 'action="[^"]+"' | head -1 | sed -E 's/action="([^"]+)"/\1/' | sed 's/\&amp;/\&/g')
echo "login action: ${ACTION:0:80}..."
# 2) submit password
R1=$(curlk -c "$CJ" -b "$CJ" -i -X POST "$ACTION" --data-urlencode "username=alice" --data-urlencode "password=alice" --data-urlencode "credentialId=")
# expect OTP form (200) now
OTPACTION=$(echo "$R1" | grep -oiE 'action="[^"]+"' | head -1 | sed -E 's/action="([^"]+)"/\1/' | sed 's/\&amp;/\&/g')
echo "otp action: ${OTPACTION:0:80}..."
CODE6=$(totp CMPDEMOTOTPSECRET123)
echo "computed TOTP: $CODE6"
# 3) submit OTP -> expect 302 to redirect_uri?code=
R2=$(curlk -c "$CJ" -b "$CJ" -i -X POST "$OTPACTION" --data-urlencode "otp=$CODE6")
LOC=$(echo "$R2" | grep -i '^location:' | head -1 | tr -d '\r')
echo "redirect: ${LOC:0:90}..."
AUTHCODE=$(echo "$LOC" | grep -oE 'code=[^&]+' | head -1 | cut -d= -f2)
if [ -z "$AUTHCODE" ]; then echo "NO CODE — OTP likely rejected. OTP form re-rendered?"; echo "$R2" | grep -oiE 'Invalid authenticator code|error' | head -3; exit 1; fi
# 4) exchange code
IDT=$(curlk "$BASE/token" -d grant_type=authorization_code -d client_id=kubernetes -d code="$AUTHCODE" -d redirect_uri="$REDIR" | jq -r .id_token)
echo "=== gold id_token acr ==="
echo "$IDT" | cut -d. -f2 | python3 -c "import sys,base64,json;p=sys.stdin.read().strip();p+='='*(-len(p)%4);d=json.loads(base64.urlsafe_b64decode(p));print(json.dumps({k:d.get(k) for k in ('acr','aud','preferred_username','auth_time','groups')}))"
echo "$IDT" > /tmp/gold_idt.txt
