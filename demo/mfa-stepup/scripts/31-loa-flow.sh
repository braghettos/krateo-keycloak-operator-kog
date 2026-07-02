set -e
kc() { docker exec keycloak /opt/keycloak/bin/kcadm.sh "$@"; }
kc config credentials --server http://localhost:8080 --realm master --user admin --password admin >/dev/null
R="-r cmp"
# clean slate if re-run
kc delete authentication/flows/mfa-browser $R 2>/dev/null || true
# top-level flow
kc create authentication/flows $R -s alias=mfa-browser -s providerId=basic-flow -s topLevel=true -s builtIn=false >/dev/null
kc create authentication/flows/mfa-browser/executions/execution $R -b '{"provider":"auth-cookie"}' >/dev/null
kc create authentication/flows/mfa-browser/executions/flow $R -b '{"alias":"mfa-forms","type":"basic-flow","description":"forms"}' >/dev/null
# level 1 subflow: LoA condition (1) + username/password
kc create authentication/flows/mfa-forms/executions/flow $R -b '{"alias":"mfa-l1","type":"basic-flow","description":"level1"}' >/dev/null
kc create authentication/flows/mfa-l1/executions/execution $R -b '{"provider":"conditional-level-of-authentication"}' >/dev/null
kc create authentication/flows/mfa-l1/executions/execution $R -b '{"provider":"auth-username-password-form"}' >/dev/null
# level 2 subflow: LoA condition (2) + OTP
kc create authentication/flows/mfa-forms/executions/flow $R -b '{"alias":"mfa-l2","type":"basic-flow","description":"level2"}' >/dev/null
kc create authentication/flows/mfa-l2/executions/execution $R -b '{"provider":"conditional-level-of-authentication"}' >/dev/null
kc create authentication/flows/mfa-l2/executions/execution $R -b '{"provider":"auth-otp-form"}' >/dev/null
echo "flow + executions created"
# dump executions for parsing on host
kc get authentication/flows/mfa-browser/executions $R
