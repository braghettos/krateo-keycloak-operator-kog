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

## ✅ Validation status — run live on GKE

The full HOP-1→HOP-2 chain was **validated end-to-end on a real GKE cluster**
(`osh-sso`): a GitHub account logs in through Keycloak, is federated into Keystone,
and lands on Horizon auto-provisioned into the `demo` project. Reproducible
walkthrough with every command/manifest: [`../../QUICKSTART-GKE-LIVE.md`](../../QUICKSTART-GKE-LIVE.md).

Two things the live run corrected vs. the first draft:

- **Mapper type is `oidc-hardcoded-group-idp-mapper`**, not `hardcoded-group-idp-mapper`
  — the non-`oidc-` variant NPEs under a `keycloak-oidc`/social broker. The mapper body
  must also carry `identityProviderAlias` (else 409).
- The live chain assigns the OpenStack project via **Keystone-side auto-provisioning**
  (a `projects` rule in the `IdentityMapping`, managed by the
  [Keystone KOG](https://github.com/braghettos/openstack-keystone-operator-kog)), so the
  federated user is dropped straight into `demo` with the `member` role — the Keycloak
  `os-project-demo` group is the authorization *source*, the Keystone mapping is the
  *sink*. Both sides are now CRs.
