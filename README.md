# keycloak-config-kog

Krateo Operator Generator (KOG) packaging that turns **Keycloak Admin API
resources into native Kubernetes custom resources**. `kubectl apply` a
`KeycloakClient` (or realm, group, mapper, …) → KOG's
[`oasgen-provider`](https://github.com/krateoplatformops/oasgen-provider) and
[`rest-dynamic-controller`](https://github.com/krateoplatformops/rest-dynamic-controller)
reconcile it against a running Keycloak.

This is the **configuration** half of the Keycloak↔Krateo↔OpenStack SSO work.
The **lifecycle** half (installing Keycloak itself) is the sibling
`keycloak-operator-blueprint`, which wraps the official Keycloak Operator.

## Resources exposed

| CR Kind (`keycloak.ogen.krateo.io/v1alpha1`) | Keycloak resource | Addressing |
| --- | --- | --- |
| `KeycloakRealm` | realm | natural key `realm` (direct) |
| `KeycloakClient` | client | `clientId` → UUID via `findby` |
| `KeycloakProtocolMapper` | protocol mapper on a client-scope / pre-existing client | `name` → UUID via `findby`; parent `clientUuid` |
| `KeycloakClientScope` | client scope | `name` → UUID via `findby` |
| `KeycloakGroup` | group | `name` → UUID via `findby` |
| `KeycloakIdentityProvider` | IdP instance (e.g. GitHub broker) | natural key `alias` (direct) |
| `KeycloakIdentityProviderMapper` | mapper on an IdP instance (e.g. GitHub → group) | `name` → UUID via `findby`; parent `alias` |
| `KeycloakAuthenticationFlow` | authentication flow (top-level container) | `alias` → UUID via `findby` |
| `KeycloakRequiredAction` | required-action provider (e.g. `CONFIGURE_TOTP`, `webauthn-register`) | natural key `alias` (direct) |
| `KeycloakAuthenticationExecution` | one execution / subflow **inside** a flow (requirement, position, authenticator config) | `(realm, flowAlias, provider \| alias)` via delegated Snowplow RESTActions |

### Authentication & MFA

`KeycloakRealm` also carries the realm **OTP** (`otpPolicy*`) and **WebAuthn**
(`webAuthnPolicy*`, incl. passwordless) **policy** fields and the top-level flow
bindings (`browserFlow`, `directGrantFlow`); `KeycloakRequiredAction` toggles the
built-in MFA actions; `KeycloakAuthenticationFlow` manages a top-level flow
container. **ACR → Level-of-Authentication** mapping is the standard
`acr.loa.map` **client attribute** (set `default.acr.values` for the default
level) — expressed directly on `KeycloakClient.attributes`, so issued tokens
carry the `acr` claim per level. See `samples/20-authentication-mfa.yaml`.

> The individual **executions/subflows inside** a flow are managed by
> `KeycloakAuthenticationExecution` — one CR per direct child of the flow named
> by `spec.flowAlias` (nesting = pointing `flowAlias` at a subflow's alias).
> Keycloak's executions API is create-then-mutate (`priority` is honored at
> create but immutable afterwards; `requirement` is a separate flow-scoped PUT),
> so this RestDefinition **delegates observe/create/update/delete to Snowplow
> `RESTAction`s** (`observeApiRef`/`createApiRef`/`updateApiRef`/`deleteApiRef`)
> — full reconcile, no plugin, no operator code. Ordering is **declarative**:
> `spec.priority` is Keycloak's native ascending weight (use spaced values,
> 10/20/30), sent at create; priority drift converges by delete + re-create.
> The sample assembles the canonical step-up ladder (LoA 1 = password,
> LoA 2 = OTP), which with `acr.loa.map` makes an `acr_values=gold` login issue
> a token with `acr=2`. Requires snowplow + authn wired into the rdc deployment
> (`URL_SNOWPLOW`/`URL_AUTHN`) — see
> [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#authentication-flows--executions-mfa--acr).

> **Mappers on a client you manage here** are best declared **inline** on the
> `KeycloakClient` via its `protocolMappers` array — fully declarative, no
> parent UUID. Use the standalone `KeycloakProtocolMapper` only for mappers on a
> client-scope or a client you don't manage as a CR.

Each maps 1:1 to a hand-curated OAS subset in `chart/assets/<key>.yaml`. The
curated schemas use field names verbatim from Keycloak's official OAS 3.0.3 so
request bodies stay wire-compatible, but trim the huge `*Representation` schemas
(RealmRepresentation alone is 152 fields) to the SSO-relevant subset.

## Two design decisions baked in

1. **`securitySchemes` patched in.** Keycloak's published OAS omits a security
   scheme; KOG only accepts `http/basic` / `http/bearer`. Every asset declares
   `bearer` (`http`/`bearer`) and applies it globally. No auth bridge is needed
   (the Admin API is genuinely Bearer — unlike the Nova KOG which had to rewrite
   `X-Auth-Token`).

2. **Short-lived token via External Secrets Operator.** Keycloak admin access
   tokens live ~minutes. Rather than a static Secret, `templates/externalsecret.yaml`
   has ESO mint a fresh token from Keycloak's token endpoint
   (`client_credentials`, a service-account client holding `realm-management`
   roles) on a `refreshInterval` shorter than the token TTL, writing it into the
   `keycloak-admin-token` Secret that every `<Kind>Configuration` references.

## Install

```bash
helm install oasgen-provider krateo/oasgen-provider -n krateo-system --create-namespace

# Pre-create the service-account client secret ESO uses to mint admin tokens:
kubectl -n krateo-system create secret generic keycloak-kog-client \
  --from-literal=clientSecret='<krateo-kog client secret>'

helm install keycloak-config-kog ./chart -n krateo-system \
  --set keycloak.baseUrl=https://<KEYCLOAK_HOST>

kubectl apply -f samples/00-configurations.yaml
kubectl apply -f samples/10-sso-realm.yaml
kubectl -n krateo-system get keycloakclients.keycloak.ogen.krateo.io -w
```

## Validation status

**`KeycloakClient` validated end-to-end** on a live kind cluster against
`oasgen-provider` 0.10 + `rest-dynamic-controller`, Keycloak 26.6.3:

- ✅ `hasSecuritySchemes: true` — the patched `bearer` scheme is recognised and
  both `KeycloakClient` + `KeycloakClientConfiguration` CRDs are generated.
- ✅ **create** — a `KeycloakClient` CR creates a real client in Keycloak via the
  Admin API (201 + empty body + `Location` header is tolerated).
- ✅ **findby/observe** — subsequent reconciles match the client by `clientId`
  ("External resource is up to date").
- ✅ **update** — changing `spec.name`/`redirectUris` propagates to Keycloak.
- ✅ **inline `protocolMappers`** — a `KeycloakClient` with a `groups` mapper in
  its `protocolMappers` array creates the client *and* the mapper; the
  post-create observe is "up to date" (no churn from the server-added mapper id).

Three corrections the spike forced into the design (now applied to all six RDs):

1. **Path params must be declared at the OPERATION level** in the OAS asset.
   oasgen-provider ignores path-item-level `parameters`, so the param (e.g.
   `realm`) never lands in the generated CRD. The generator now emits per-op params.
2. **Server-generated id must be excluded from spec.** The `{id}` path param is
   added to the CRD as *required*; since it is server-assigned, each RD uses
   `excludedSpecFields: [id]` + `requestFieldMapping` sourcing it from
   `status.id` (populated by `findby`). `configurationFields` is NOT used for
   path params (doing so drops them).
3. **Nested array fields need a `$ref`.** oasgen-provider drops inline
   array-of-object items, so `protocolMappers` references a named
   `ClientProtocolMapperEntry` schema instead of an inline object.

**The seven core resources validated** on a live kind cluster (Keycloak 26.6.3):
`KeycloakRealm`, `KeycloakGroup`, `KeycloakClientScope`, `KeycloakClient`,
`KeycloakProtocolMapper`, `KeycloakIdentityProvider`, and
`KeycloakIdentityProviderMapper` each reconcile into the real Keycloak.

**Authentication & MFA resources — validation status.** The realm OTP/WebAuthn
policy fields and the ACR client-attribute path extend already-validated
resources (`KeycloakRealm`/`KeycloakClient`) and are exercised by
`helm template` + schema checks. `KeycloakRequiredAction` (natural-key `alias`,
direct) and `KeycloakAuthenticationFlow` (natural-key `alias` → `findby` → `id`)
reuse the exact addressing patterns already proven by `KeycloakIdentityProvider`
and `KeycloakClient` respectively; **live-cluster reconcile of these two is
pending**. One known Keycloak-specific caveat: `register-required-action` is the
create endpoint for a brand-new action, but the base actions (`CONFIGURE_TOTP`,
`webauthn-register`) ship built-in, so reconcile normally observes + updates
rather than creates.

**`KeycloakAuthenticationExecution` — validation status.** The RESTAction
delegation mechanics (`observeApiRef` existence/drift gating, level-based
create convergence, finalizer-held delete) are covered by unit tests in the
`rest-dynamic-controller` it ships with; the chart renders + lints clean.
The **Keycloak API contract and every jq program were validated against a live
Keycloak 26.0.8**: `hack/validate-executions-live.sh` replays the exact
observe/create/update/delete stage sequences (same endpoints, same jq extracted
from the rendered manifests) to build the full step-up ladder from the sample,
then injects requirement / priority / config drift and verifies convergence and
finalizer-style 404 deletion. Declarative `priority` at create, priority
immutability, and recreate-convergence are live-verified facts, not
assumptions. **The remaining step is in-cluster reconcile through
oasgen + rdc + snowplow themselves** (needs a full Krateo control plane with
`URL_SNOWPLOW`/`URL_AUTHN` wired into the rdc deployment).

Resource-specific note surfaced by validation:

- **`KeycloakIdentityProviderMapper` needs both `alias` (path) *and*
  `identityProviderAlias` (body).** Keycloak returns a misleading
  `409 Duplicate resource` if `identityProviderAlias` is omitted.

### ESO token path — validated
The `auth.externalSecret` path works end-to-end: ESO mints a fresh admin bearer
token from Keycloak's token endpoint (via the `krateo-kog` service-account
client) into `keycloak-admin-token`, and it calls the Admin API successfully.
Requirements confirmed on ESO ≥ 0.19:

- the client-secret Secret (`keycloak-kog-client`) must carry the label
  **`external-secrets.io/type: webhook`** (ESO refuses to read it otherwise);
- the `krateo-kog` client needs `serviceAccountsEnabled` + admin rights
  (the realm `admin` role, or the specific `realm-management` roles).

Fixes this forced into the chart's `externalsecret.yaml`: `ExternalSecret`
`external-secrets.io/v1` (v1beta1 is removed); the Webhook body references the
secret as `.kog.clientSecret` (name-then-key); and `result.jsonPath: "$"`
returns the whole token response so the template can pick `.access_token`.

## Regenerating the OAS assets

`chart/assets/*.yaml` are generated by `hack/gen_oas_assets.py` from the field
lists curated there. Edit that script and re-run it to change the exposed field
surface.
