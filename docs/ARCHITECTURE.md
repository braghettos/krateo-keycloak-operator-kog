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

**Deliberately not modelled as a plain RestDefinition: the executions *inside* a
flow.** Keycloak's `authentication/executions` API is **create-then-mutate** —
an execution is created at `.../executions/execution`, its `requirement` is set
by a `PUT` to a *different* path (`.../executions`), and ordering is done with
`raise-priority` / `lower-priority` **move operations**. The plain OAS
`verbsDescription` (one path per verb) cannot sequence that.

**The shipped `rest-dynamic-controller` handles it without a plugin.** A
`RestDefinition` can delegate any of its four lifecycle verbs to a **Snowplow
`RESTAction`** — `observeApiRef` / `createApiRef` / `updateApiRef` /
`deleteApiRef` — wired straight into the reconcile loop (verified in
`krateo-rest-dynamic-controller`: `observe_restaction.go`, `mutate_restaction.go`):

- **`observeApiRef`** resolves a RESTAction that GETs the flow's executions,
  selects this one by provider, and composes `.status` (`{id, requirement,
  index}`). Its `notFoundExpr` (gojq over `{spec,status}`) reports absence ⇒
  **create**; `upToDateExpr` reports requirement/order drift ⇒ **update**.
- **`createApiRef`** POSTs the execution. Create is re-invoked each reconcile
  until observe reports existence, so the non-idempotent POST is safe *precisely
  because observe gates it* (it fires only when absent).
- **`updateApiRef`** resolves the id and PUTs the requirement (+ ordering).
- **`deleteApiRef`** DELETEs by id and is **finalizer-verified**
  (`externalResourceStillExists` re-probes the get verb) — a RESTAction returns
  200 even if a teardown stage failed, so success alone isn't proof.

Snowplow is **not a new dependency**: rdc already resolves GVK→GVR through it
(pluralizer → `/api-info/names`) and it is the RESTAction resolver. So the
executions resource is a `RestDefinition` with apiRefs + a few small RESTActions
— full apply/resync/delete reconcile, no new service, no operator code.

**What would still force a plugin — guarantees, not verbs:** a non-idempotent
mutation with *no observe to gate it*; transactional/all-or-nothing across stages
(Snowplow returns 200 even on an inner-stage failure — RDC has no rollback);
logic needing I/O, wall-clock, randomness or cross-reconcile state that sandboxed
gojq can't express; payloads > ~48 KiB or non-HTTP auth wrappers. For Keycloak
executions only **ordering** (iterating `raise/lower-priority` toward a target
index) sits near that line — it is expressible as a jq-computed move-list fanned
out by a RESTAction `dependsOn` iterator and converges over resyncs (Keycloak
reads are synchronous), so it is the one part to validate live; create /
requirement / delete are plainly apiRef-expressible.

**This executions resource is the tracked follow-up** (the pure-RD surface above
lands first) — as apiRefs + RESTActions, not a plugin.

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
