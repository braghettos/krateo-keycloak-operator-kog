set -e
kc() { docker exec keycloak /opt/keycloak/bin/kcadm.sh "$@"; }
kc config credentials --server http://localhost:8080 --realm master --user admin --password admin >/dev/null
R="-r cmp"
setreq() { kc update authentication/flows/mfa-browser/executions $R -b "{\"id\":\"$1\",\"requirement\":\"$2\"}"; }
EX=$(kc get authentication/flows/mfa-browser/executions $R)
id_by() { echo "$EX" | jq -r ".[] | select(.displayName==\"$1\") | .id" | sed -n "${2:-1}p"; }
COOKIE=$(id_by "Cookie"); FORMS=$(id_by "mfa-forms"); L1=$(id_by "mfa-l1"); L2=$(id_by "mfa-l2")
UPW=$(id_by "Username Password Form"); OTP=$(id_by "OTP Form")
LOA1=$(echo "$EX" | jq -r '.[] | select(.providerId=="conditional-level-of-authentication") | .id' | sed -n 1p)
LOA2=$(echo "$EX" | jq -r '.[] | select(.providerId=="conditional-level-of-authentication") | .id' | sed -n 2p)
echo "cookie=$COOKIE forms=$FORMS l1=$L1 l2=$L2 loa1=$LOA1 loa2=$LOA2 upw=$UPW otp=$OTP"
setreq "$COOKIE" ALTERNATIVE
setreq "$FORMS" ALTERNATIVE
setreq "$L1" CONDITIONAL
setreq "$LOA1" REQUIRED
setreq "$UPW" REQUIRED
setreq "$L2" CONDITIONAL
setreq "$LOA2" REQUIRED
setreq "$OTP" REQUIRED
# LoA configs
kc create authentication/executions/$LOA1/config $R -b '{"alias":"loa-1","config":{"loa-condition-level":"1","loa-max-age":"36000"}}' >/dev/null
kc create authentication/executions/$LOA2/config $R -b '{"alias":"loa-2","config":{"loa-condition-level":"2","loa-max-age":"0"}}' >/dev/null
echo "requirements + LoA configs set"
# bind flow to the kubernetes client
FLOWID=$(kc get authentication/flows $R | jq -r '.[] | select(.alias=="mfa-browser") | .id')
CID=$(kc get clients $R -q clientId=kubernetes --fields id --format csv --noquotes | tail -1)
kc update clients/$CID $R -b "{\"authenticationFlowBindingOverrides\":{\"browser\":\"$FLOWID\"}}"
echo "bound mfa-browser ($FLOWID) to client kubernetes ($CID)"
