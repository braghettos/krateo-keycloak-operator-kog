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
`raise-priority` / `lower-priority` **move operations**. `rest-dynamic-controller`
is a flat CRUD engine (it matches path params by field name and sends spec
fields as a body; it has no verb-sequencing), so a single declarative
RestDefinition cannot express create + requirement + reorder.

Two mechanisms can add that without touching the operator:

1. **A snowplow `RESTAction`** (leading option). A `RESTAction` is a declarative
   call-chain: each `api[]` stage has a verb, payload, `endpointRef` (base URL +
   auth), `dependsOn` (with an `iterator` to fan out over a list) and a JQ
   `filter`. That expresses `POST flow → POST execution (dependsOn flow) → PUT
   requirement → raise/lower-priority (iterated)`, threading ids via JQ and
   authing through an Endpoint backed by the same admin token. Crucially it adds
   **no new dependency and no new code**: `rest-dynamic-controller` already
   hard-depends on snowplow at runtime (its pluralizer resolves GVK→GVR via
   snowplow's `/api-info/names`), and that same snowplow is the RESTAction
   resolver. A RESTAction is *invocation-driven* (resolved when called), which
   suits provisioning a flow as a portal/onboarding action (D18).
2. **A facade plugin** (the `oxide-rest-dynamic-controller-plugin` pattern): a
   small stateless service that rdc drives with plain CRUD (point the OAS
   `servers[0].url` at it) while it internally orchestrates the sequence. This
   buys full apply/resync/delete **reconcile** semantics for the flow itself, at
   the cost of a new service to build and run. Choose this only if the flow must
   behave like every other reconciled CR here; it is not needed to avoid a
   snowplow dependency (there is no new one to avoid).

**Managing individual executions/subflows is tracked as the follow-up to this
work** (the pure-RD surface above lands first); the RESTAction is the current
lead.

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
