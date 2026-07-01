# Demo — GitHub → Keycloak → OpenStack SSO

Log in with **GitHub**, then open **OpenStack Horizon** already signed in. This
is the base [`../sso-end-to-end`](../sso-end-to-end) demo with **one extra hop
in front**: Keycloak brokers the login to GitHub instead of using its own login
form. Everything downstream is identical.

```
 You ─▶ GitHub ─▶ Keycloak ─▶ Keystone ─▶ Horizon
        (OAuth)   (broker +    (OIDC       (WebSSO,
                  default      federation) already
                  group)                   signed in)
   HOP 1 (this folder): Keycloak federates TO GitHub  → Keycloak = SP/broker
   HOP 2 (base demo):   Keystone federates TO Keycloak → Keycloak = IdP
```

The shared Keycloak session is still the glue: once GitHub has established the
Keycloak session (HOP 1), the Horizon→Keystone→Keycloak redirect completes
silently (HOP 2).

## What's in this folder

| File | What it does |
| --- | --- |
| `00-configurations.yaml` | per-Kind `*Configuration` CRs (bearer token refs), incl. the new `KeycloakIdentityProviderMapperConfiguration` |
| `10-github-idp.yaml` | the GitHub broker + the `os-project-demo` group + a `KeycloakIdentityProviderMapper` that puts GitHub users in that group |

Everything else — realm, `keystone` client + `groups` mapper, Keystone
federation values, Horizon WebSSO values, the Krateo Markdown widget — comes
straight from [`../sso-end-to-end`](../sso-end-to-end).

## Prerequisites

1. The Keycloak `krateo` realm + `keystone` client (from `../sso-end-to-end`
   steps, or the top-level [`../../QUICKSTART.md`](../../QUICKSTART.md)).
2. A **GitHub OAuth App** (GitHub → Settings → Developer settings → OAuth Apps)
   with callback URL `https://<KEYCLOAK_HOST>/realms/krateo/broker/github/endpoint`.
   Note its Client ID + secret.

## Steps

```bash
# 1. the config CRs
kubectl apply -f 00-configurations.yaml
# 2. GitHub broker + default-group mapper (fill in the OAuth App id/secret + hosts)
kubectl apply -f 10-github-idp.yaml
# 3. the rest of the chain (realm/client/mapper, Keystone, Horizon, widget)
kubectl apply -f ../sso-end-to-end/   # + the Keystone/Horizon Helm values
```

Now the Keycloak login page shows a **"GitHub"** button (set the realm's
`hideOnLogin`/first-broker-login options if you want GitHub to be the *only*
choice). Log in with GitHub → you're a `krateo`-realm user in `os-project-demo`
→ click the Krateo widget → Horizon opens in the `demo` project.

## Authorization: default group vs. per-team

This demo uses the simplest, fully-declarative option: **`hardcoded-group-idp-mapper`
→ every GitHub user lands in `os-project-demo`** (one shared OpenStack project).

For **per-team → per-project** mapping you'd add more `KeycloakIdentityProviderMapper`
CRs, but note GitHub is OAuth2 and its token does **not** carry team claims — so
true team-based group mapping needs the GitHub org/teams to be fetched and matched
(an advanced/custom mapper + the `read:org` scope already requested above). The
hardcoded-group approach is what most GitHub→Keycloak→app setups use in practice.

## ⚠️ Validation status

- ✅ The KOG side is real: `KeycloakIdentityProvider` and the new
  `KeycloakIdentityProviderMapper` are generated CRDs (chart renders clean,
  7 resources). `KeycloakClient` was validated end-to-end on a live cluster;
  these two follow the same proven RestDefinition pattern.
- ⚪️ The GitHub broker + the full HOP-1→HOP-2 flow have **not** been run live
  here (needs a running Keycloak + OpenStack + a real GitHub OAuth App). Confirm
  when you run it: the GitHub OAuth App callback URL, and that
  `hardcoded-group-idp-mapper`'s `group` path matches the `KeycloakGroup` name.
