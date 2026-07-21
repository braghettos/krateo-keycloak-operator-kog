# Keycloak for Krateo PlatformOps + OpenStack Horizon SSO

Two complementary Krateo deliverables that bring Keycloak into the platform so
users authenticated via Keycloak are **automatically logged into OpenStack
Horizon** (shared Keycloak SSO session — no token bridging).

```
                         ┌──────────────────┐
   ── OIDC client A ────►│     KEYCLOAK     │◄── one browser SSO session
      (krateo-authn)     │   realm: krateo  │    (the "auto-login" glue)
   ── OIDC client B ────►│                  │
      (keystone)         └──────────────────┘
        ▲                   ▲            ▲
        │ lifecycle         │ config     │
  ┌─────┴───────────┐  ┌────┴─────────────────┐
  │ keycloak-       │  │ keycloak-config-kog  │
  │ operator-       │  │ (KOG: realm/client/  │
  │ blueprint       │  │  mapper/group/IdP…)  │
  └─────────────────┘  └──────────────────────┘
```

## The two deliverables

| Dir | Role | Tech |
| --- | --- | --- |
| [`krateo-keycloak-blueprint/`](https://github.com/braghettos/krateo-keycloak-blueprint) | **Lifecycle** — deploy/manage the Keycloak server | Krateo `CompositionDefinition` → chart → official Keycloak Operator (`Keycloak` CR) |
| [`krateo-keycloak-operator-kog/`](https://github.com/braghettos/krateo-keycloak-operator-kog) | **Configuration** — Keycloak Admin API resources as CRs | KOG (`oasgen-provider` + `rest-dynamic-controller`) over Keycloak's official OAS 3.0.3 |

They connect at exactly one point: the bearer **`keycloak-admin-token`** Secret
(minted/rotated by External Secrets Operator) that the config KOG uses to call
the server the blueprint stands up.

## How this fits the wider SSO plan

- **Krateo side:** the `krateo-authn` client + `groups` mapper feed Krateo's
  `authn` `oidc` strategy (`OIDCConfig`, `additionalScopes: groups`).
- **OpenStack side:** the `keystone` client + `groups` mapper feed Keystone OIDC
  federation (`mod_auth_openidc`); Horizon WebSSO (already templated in the
  `openstack-as-a-service` Horizon chart) redirects into it. Keycloak groups →
  Keystone groups → project/role, with the **Keystone mapping rules rendered via
  the blueprint's Helm templates**.

## Build / KOG mechanics decisions (why it looks like this)

1. **Operator for lifecycle, KOG for config** — clean separation; avoids two
   systems owning the same realm. Bitnami chart intentionally avoided (deprecated
   Aug 2025).
2. **`securitySchemes` patched into every OAS asset** — Keycloak's published OAS
   omits it; KOG needs `http/bearer`. The Admin API is genuinely Bearer, so
   (unlike the Nova KOG) **no auth-bridge proxy** is required.
3. **Short-lived admin token via ESO** — a `Webhook` generator mints a fresh
   token (`client_credentials`) into the Secret on a sub-TTL interval.
4. **`findby` for UUID resources** — client/group/client-scope/mapper are
   addressed by server-generated UUIDs; `findby` resolves them from natural keys
   (clientId/name). realm + identity-provider use direct natural keys
   (`realm`/`alias`).
5. **`Keycloak`-prefixed CR kinds** — avoids crdgen collisions with same-named
   lowercase body properties (the Nova `Server` vs `server` failure mode).

## Authentication flows & executions (MFA / ACR)

The KOG exposes the *login-configuration* surface too:

- **`KeycloakRealm`** carries the **OTP** (`otpPolicy*`) and **WebAuthn**
  (`webAuthnPolicy*`, incl. passwordless) **policy** fields, plus top-level flow
  bindings (`browserFlow`, `directGrantFlow`).
- **`KeycloakRequiredAction`** manages required-action providers by `alias`
  (e.g. `CONFIGURE_TOTP`, `webauthn-register`). Base actions ship built-in, so
  reconcile normally observes + updates their enabled/default/priority state.
- **`KeycloakAuthenticationFlow`** manages a **top-level flow container**
  (`alias` + metadata), addressed by natural key like the other resources.
- **ACR → LoA** is a standard **client attribute** (`acr.loa.map`) already
  expressible on `KeycloakClient.attributes` — no new field needed; set
  `default.acr.values` for the client's default requested level. This is what
  makes issued tokens carry the `acr` claim per level.

**The executions *inside* a flow are not a plain RestDefinition.** Keycloak's
`authentication/executions` API is **create-then-mutate** — an execution is
created at `.../executions/execution` (its `priority` ordering weight is honored
at create — verified live on 26.0.8 — but **immutable afterwards**), and its
`requirement` is set by a `PUT` to a *different* path (`.../executions`). The
plain OAS `verbsDescription` (one path per verb) cannot sequence that.

**The shipped `rest-dynamic-controller` handles it without a plugin**, and this
is how **`KeycloakAuthenticationExecution`** is built: a `RestDefinition` that
delegates its four lifecycle verbs to **Snowplow `RESTAction`s** —
`observeApiRef` / `createApiRef` / `updateApiRef` / `deleteApiRef` — wired
straight into the reconcile loop (verified in `krateo-rest-dynamic-controller`:
`observe_restaction.go`, `mutate_restaction.go`). One CR manages **one direct
child** (execution *or* subflow, `spec.subFlow`) of the flow named by
`spec.flowAlias`; nesting = pointing `flowAlias` at a subflow's alias (aliases
are realm-unique). Natural key: `(realm, flowAlias, provider)` for executions,
`(realm, flowAlias, alias)` for subflows.

- **`observeApiRef`** (`*-authenticationexecution-observe`) GETs the flow's
  executions, selects this one among the **level-0** entries and composes
  `.status` (`{found, id, requirement, index, level, priority, configured}`).
  Its `notFoundExpr` (gojq over `{spec,status}`) reports absence ⇒ **create**;
  `upToDateExpr` reports requirement / priority / config-presence
  drift ⇒ **update**.
- **`createApiRef`** POSTs `.../executions/execution` (`{provider, priority?}`)
  or `.../executions/flow` (`{alias, type, priority?}`) — `priority` is
  Keycloak's native ordering weight, so the child lands in the right position
  **by construction** (no move operations). Create is re-invoked each reconcile
  until observe reports existence, so the non-idempotent POST is safe *precisely
  because observe gates it* (it fires only when absent).
- **`updateApiRef`** re-lists, PUTs the desired `requirement`, converges
  **priority drift by delete + re-create** (priority is immutable in Keycloak;
  two iterator stages gated on the same drift condition — an empty iterator
  array is the "does not apply" case), and applies the authenticator `config`
  (POST `.../executions/{id}/config` when none is attached, idempotent PUT
  `.../authenticator-config/{id}` otherwise).
- **`deleteApiRef`** re-lists and DELETEs by id, tolerating an already-gone
  parent flow (the iterator emits nothing and the finalizer is released). The
  RestDefinition also declares a plain **get verb** on
  `.../authentication/executions/{executionId}` (`executionId` ← `status.id`),
  so the finalizer is released only once that GET returns a real **404**.

**Deployment prerequisites (the honest dependency picture):** the RESTActions
are resolved by **snowplow** and rdc authenticates to it via the **authn**
service — both part of a standard Krateo install, but the **stock oasgen-provider
rdc templates do not wire them**: the cluster's `rdc-deployment` /
`rdc-configmap` ConfigMaps must set `URL_SNOWPLOW` and `URL_AUTHN` and project an
authn-audience ServiceAccount token (default path
`/var/run/secrets/krateo.io/serviceaccount/token`), and the controller identity
needs a `<identity>-clientconfig` Secret in the authn namespace plus RBAC `get`
on `restactions.templates.krateo.io` in this chart's namespace. With
`URL_SNOWPLOW` unset, every reconcile of this resource hard-errors (no OAS
fallback). The RESTActions reach Keycloak through a snowplow `Endpoint`-shaped
Secret (`server-url` + the same ESO-rotated admin bearer — a second projection
in `templates/externalsecret.yaml`). Full apply/resync/delete reconcile, no new
service, no operator code.

**Documented limitations (all converge, none corrupt):** priority drift is
converged by recreate — the recreated execution lands `DISABLED` (and a
recreated **subflow** lands empty; its children CRs re-create themselves on
their following reconciles), so requirement/config settle one-two resyncs later;
config drift is **presence-only** (a value-only change is re-applied on the next
requirement/priority drift, not by itself); duplicate providers under the same
parent are not distinguishable (declare one CR per `(flowAlias, provider)`);
the **natural-key fields are create-only** — editing `provider`/`flowAlias`/
`alias`/`subFlow` on a live CR re-targets the reconcile at a *new* execution and
orphans the old one (delete + re-create the CR instead); mutation-stage errors
accumulate under `errorKey`s inside the RESTAction resolve but are **not
projected into the CR status** — degradation shows up as the observe reporting
the same absence/drift on the next reconcile (level-based convergence), with
details in the rdc/snowplow logs.

**What would still force a plugin — guarantees, not verbs:** a non-idempotent
mutation with *no observe to gate it*; transactional/all-or-nothing across stages
(Snowplow returns 200 even on an inner-stage failure — RDC has no rollback);
logic needing I/O, wall-clock, randomness or cross-reconcile state that sandboxed
gojq can't express; payloads > ~48 KiB or non-HTTP auth wrappers. Keycloak
executions need none of these.

`samples/20-authentication-mfa.yaml` assembles the canonical **step-up ladder**
(LoA 1 = password, LoA 2 = OTP, via `conditional-level-of-authentication`
config) from these CRs; combined with the client's `acr.loa.map` attribute that
is what makes an `acr_values=gold` login issue a token carrying `acr=2`.
**Live-cluster reconcile of the executions resource is the remaining validation
step** (see README → Validation status).

## Status

Both charts `helm lint` clean and `helm template` to valid manifests. The KOG's
runtime behaviour is **validated for `KeycloakClient`** (create/findby/update on a live kind cluster; other five RDs share the proven pattern) —
see the krateo-keycloak-operator-kog README → "Validation status" for the spike checklist
(start with `KeycloakClient` only). `_reference/` holds the upstream OAS and the
asset generator.

## Suggested order to take this live

1. Install `oasgen-provider`, `rest-dynamic-controller`, External Secrets
   Operator, and the Keycloak Operator (cluster prereqs).
2. Deploy `keycloak-operator-blueprint` → a running Keycloak.
3. Create the `krateo-kog` service-account client + its Secret.
4. Deploy `keycloak-config-kog`; run the **`KeycloakClient` spike**; then enable
   the other five resources.
5. Apply `samples/10-sso-realm.yaml` to provision the realm/clients/mapper/group.
6. Wire Keystone OIDC federation + Horizon WebSSO (the `openstack-as-a-service`
   side) and the Krateo `OIDCConfig`.
