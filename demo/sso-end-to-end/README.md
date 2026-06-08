# Demo — end-to-end SSO: Krateo → Keycloak → OpenStack Horizon

The payoff: a **Markdown widget in the Krateo portal** with a link that opens
**OpenStack Horizon already logged in** — no second login. This demo assembles
all five links of the chain.

```
  ┌── LINK 2 ── Krateo portal ──(OIDC: krateo-authn)──┐
  │   user logs into Krateo via Keycloak              │
  │   → browser now holds a KEYCLOAK SSO SESSION      ▼
  │                                          ┌──────────────────┐
  │   LINK 5: Markdown widget link ─────────►│     KEYCLOAK     │
  │   to Horizon WebSSO                       │   realm: krateo  │
  │        │                                  └──────────────────┘
  │        ▼                                        ▲ (silent: session exists)
  │   Horizon ──WebSSO (LINK 4)──► Keystone ──OIDC federation (LINK 3)──┘
  │                                   │ maps `groups` → project/role
  └───────────────────────────────────┘
```

The "magic" is just a **shared Keycloak session**: once LINK 2 has happened,
LINK 5's link completes LINKs 4→3 silently.

## The pieces in this folder

| File | Link | What it configures |
| --- | --- | --- |
| `01-krateo-oidcconfig.yaml` | 2 | Krateo `authn` OIDC login via the `krateo-authn` client |
| `02-keystone-federation.values.yaml` | 3 | Keystone Apache as an OIDC RP (`mod_auth_openidc`) of the `keystone` client |
| `02b-keystone-mapping.json` | 3 | claims → Keystone shadow user + `groups` (→ project/role) |
| `03-horizon-websso.values.yaml` | 4 | Horizon WebSSO → Keystone federated endpoint |
| `04-krateo-markdown-widget.yaml` | 5 | the auto-login Markdown widget |

## Prerequisites (LINK 1 — already done)

The Keycloak `krateo` realm + the `keystone`/`krateo-authn` clients + the
`groups` mapper, provisioned by the KOG. See [`../../QUICKSTART.md`](../../QUICKSTART.md).
You also need, deployed and reachable over **consistent HTTPS hostnames**:

- a running **Keycloak** (the `krateo-keycloak-blueprint`),
- a running **OpenStack** (`braghettos/krateo-openstack-blueprint` — Keystone + Horizon),
- a running **Krateo** portal (frontend + `authn` + snowplow widgets).

## Steps

1. **LINK 2 — Krateo login via Keycloak.** Fill the secret + hosts and apply:
   ```bash
   kubectl apply -f 01-krateo-oidcconfig.yaml
   # verify: GET https://<KRATEO_HOST>/authn/strategies lists the `oidc` strategy
   ```
   Log into Krateo with "Login with Keycloak". You now hold a Keycloak session.

2. **LINK 3 — Keystone federation.** Merge `02-keystone-federation.values.yaml`
   into the keystone Composition values and redeploy. Then create the federation
   objects (the `groups` your mapping references must map to Keystone groups that
   carry role assignments on projects):
   ```bash
   openstack domain create federated
   openstack identity provider create --remote-id https://<KEYCLOAK_HOST>/realms/krateo keycloak
   openstack mapping create --rules 02b-keystone-mapping.json keycloak_mapping
   openstack federation protocol create openid --identity-provider keycloak --mapping keycloak_mapping
   # example authz: a keystone group matching a Keycloak group, granted a role on a project
   openstack group create --domain federated os-project-demo
   openstack role add --group os-project-demo --group-domain federated --project demo member
   ```

3. **LINK 4 — Horizon WebSSO.** Merge `03-horizon-websso.values.yaml` into the
   horizon Composition values and redeploy. Horizon login now offers
   "Login with Keycloak".

4. **LINK 5 — the widget.** Fill the hosts and apply:
   ```bash
   kubectl apply -f 04-krateo-markdown-widget.yaml
   ```
   Add `openstack-sso-link` to a Krateo page/panel. Clicking the link opens
   Horizon **already authenticated**.

## Validate the payoff

Logged into Krateo (LINK 2 done), click the widget link. Expected: a brief
redirect flash (Horizon → Keystone → Keycloak → back) and the Horizon dashboard
renders with no login prompt, scoped to the project your Keycloak group grants.

## ⚠️ Validation status

- **Validated** here (on kind): the Keycloak realm/clients/`groups` mapper (the
  KOG side) that everything else consumes.
- **Authored, not yet run live**: LINKs 2–5 require a running OpenStack + Krateo
  portal (not deployed on the demo kind cluster). Tune before/while running:
  - the Keystone image must contain `mod_auth_openidc`;
  - the mapping `remote` claim names (`OIDC-groups`, …) must match what
    `mod_auth_openidc` passes (governed by `OIDCClaimPrefix`);
  - `remote_id_attribute` (`HTTP_OIDC_ISS`) must equal the realm token issuer;
  - all hostnames/redirect URIs must be HTTPS and consistent across the three apps.
- **Logout/SLO** is intentionally out of scope (timeout-based for now).
