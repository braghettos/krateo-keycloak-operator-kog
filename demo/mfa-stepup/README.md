# MFA step-up for critical CMP operations — end-to-end prototype

Enforces the requirement:

> *"La CMP deve imporre MFA per accessi amministrativi e deve poter richiedere MFA
> step-up al momento di operazioni critiche (es. gestione ruoli, gestione
> federazione, export consumi)."*

interpreted at the Kubernetes layer as: **applying a critical Custom Resource
(federation / roles) must require an MFA-stepped-up token; a password-only session
is rejected.**

This is **Pattern B** from the analysis — a *policy gate*: the enforcement point is
Kubernetes admission, consuming Keycloak's `acr` (Authentication Context Class
Reference) claim. It is **fully runnable locally** (kind + dockerized Keycloak).

> **Scope of this demo:** it builds the Keycloak LoA ladder **imperatively**
> (the `kcadm` scripts `31-loa-flow.sh` / `32-loa-wire.sh`) against client
> `kubernetes` with `acr_values=2`, to keep the admission-gate story self-contained
> and local. To see the **same `acr=2` outcome produced by the
> `KeycloakAuthenticationExecution` CRs this repo ships** (client `acr-app`,
> `acr_values=gold`, flow reconciled by the control plane), use
> [`demo/acr-via-crs`](../acr-via-crs/README.md).

> Why local kind and not the GKE cluster? The mechanism requires configuring the
> **kube-apiserver's authentication** (Structured Authentication Config) and an
> **HTTPS OIDC issuer** — neither is possible on a managed control plane (GKE/EKS/AKS).
> On a self-managed cluster the exact same artifacts apply.

## The chain

```
kubectl apply <critical CR>
        │  (bearer = Keycloak OIDC id_token)
        ▼
kube-apiserver — Structured Authentication Config
        │  validates JWT (issuer/sig/aud), maps claims:
        │    preferred_username → user   groups → groups
        │    acr        → extra["cmp.krateo.io/acr"]
        │    auth_time  → extra["cmp.krateo.io/auth_time"]
        ▼
RBAC (allows: user is in group cmp-admins)
        ▼
ValidatingAdmissionPolicy  require-mfa-stepup
        │  only-oidc-users AND resource in {federation, roles, ...}
        │  require  extra["cmp.krateo.io/acr"] == "2"
        ▼
   acr=1 → DENY        acr=2 → ADMIT
```

Keycloak side: a **Level-of-Authentication (LoA) step-up** browser flow.
- Level 1 = username + password  → `acr=1`
- Level 2 = + **TOTP** (authenticator app) → `acr=2`
- The client requests `acr_values=2` for a critical action; Keycloak prompts *only*
  for the missing factor (the step-up) and stamps `acr=2` + a fresh `auth_time`.

TOTP is used here (built-in, no gateway). Swapping to **WebAuthn/passkeys** changes
only the Keycloak flow — the Kubernetes policy is factor-agnostic (it only checks `acr`).

## Proven result

Same user (`alice`, group `cmp-admins`, RBAC-allowed), same CR, only the token differs:

| Token | `acr` | `kubectl apply` IdentityFederationProvider |
|-------|-------|--------------------------------------------|
| password only (`acr_values` unset / 1) | `1` | ❌ denied by `require-mfa-stepup` |
| password + TOTP (`acr_values=2`) | `2` | ✅ admitted, CR created |

Denial message:
```
ValidatingAdmissionPolicy 'require-mfa-stepup' denied request: CMP critical
operation on identityfederationproviders requires MFA step-up (acr=2). Your token
has acr=1. Re-authenticate with step-up (acr_values=2) and retry.
```

## Layout

| Path | What |
|------|------|
| `certs/` | self-signed CA + Keycloak TLS cert (apiserver needs an HTTPS issuer) |
| `manifests/auth-config.yaml` | kube-apiserver **Structured Authentication Config** (claim → extra mapping) |
| `manifests/kind-config.yaml` | kind cluster mounting the auth config into the apiserver |
| `manifests/cluster.yaml` | CRDs + RBAC + the `require-mfa-stepup` ValidatingAdmissionPolicy |
| `manifests/sample-cr.yaml` | a critical CR (`IdentityFederationProvider`) |
| `scripts/30-seed-user-otp.sh` | create `alice` with password + a seeded TOTP secret + group |
| `scripts/31-loa-flow.sh` / `32-loa-wire.sh` | build & wire the Keycloak LoA step-up browser flow |
| `scripts/50-mint-gold-token.sh` | scripted step-up login (password → TOTP) → `acr=2` token |
| `scripts/totp.py` | TOTP generator matching Keycloak (HMAC-SHA1 over the raw secret bytes) |

## Reproduce

```bash
# 1. certs
cd certs && ./ (see scripts) ; cd ..
# 2. kind cluster with the apiserver auth config
kind create cluster --config manifests/kind-config.yaml --image kindest/node:v1.32.2
# 3. Keycloak (TLS, on the kind network so the apiserver can reach https://keycloak:8443)
docker run -d --name keycloak --network kind --network-alias keycloak -p 8443:8443 \
  -v $PWD/certs/kc.crt:/certs/kc.crt:ro -v $PWD/certs/kc.key:/certs/kc.key:ro \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
  -e KC_HOSTNAME=https://keycloak:8443 \
  -e KC_HTTPS_CERTIFICATE_FILE=/certs/kc.crt -e KC_HTTPS_CERTIFICATE_KEY_FILE=/certs/kc.key \
  quay.io/keycloak/keycloak:26.0 start-dev
# 4. realm cmp: client `kubernetes`, user alice+OTP, groups, LoA step-up flow
bash scripts/30-seed-user-otp.sh && bash scripts/31-loa-flow.sh && bash scripts/32-loa-wire.sh
# 5. cluster policy
kubectl apply -f manifests/cluster.yaml
# 6. DENY (password only)
IDT=$(curl -s --resolve keycloak:8443:127.0.0.1 --cacert certs/ca.crt \
  https://keycloak:8443/realms/cmp/protocol/openid-connect/token \
  -d grant_type=password -d client_id=kubernetes -d username=alice -d password=alice -d scope=openid | jq -r .id_token)
KUBECONFIG=/dev/null kubectl --server=<apiserver> --certificate-authority=certs/kind-ca.crt \
  --token="$IDT" apply -f manifests/sample-cr.yaml     # → denied (acr=1)
# 7. ALLOW (step-up)
bash scripts/50-mint-gold-token.sh                     # writes /tmp/gold_idt.txt (acr=2)
KUBECONFIG=/dev/null kubectl --server=<apiserver> --certificate-authority=certs/kind-ca.crt \
  --token="$(cat /tmp/gold_idt.txt)" apply -f manifests/sample-cr.yaml   # → admitted
```

## Hardening notes (beyond the prototype)

- **Freshness = "at the moment of the operation."** The policy can also require
  `now - auth_time < N minutes` (auth_time is already mapped to `extra`). Direct-grant
  tokens carry no `auth_time`; the browser step-up flow does (shown here).
- **Scope tightly.** `matchConstraints` lists only the sensitive kinds
  (federation/roles). Everything else is unaffected.
- **`only-oidc-users` matchCondition** exempts controllers/ServiceAccounts and the
  break-glass cert admin — tune to your threat model.
- **Interactive step-up UX** (a real pop-up at the moment of action) belongs in the
  **CMP portal/API** (Pattern A): it redirects to Keycloak with `acr_values=2`. This
  admission gate is the defense-in-depth for direct `kubectl`.
- **Factor:** swap TOTP → WebAuthn/passkeys in the Keycloak flow; no cluster change.
