# Screenshots for the live GKE walkthrough

These frames were captured live on GKE cluster `osh-sso` while validating the
GitHub → Keycloak → Keystone → Horizon SSO chain (federated user `braghettos`
auto-provisioned into the `demo` project). Drop the captured PNGs here with the
filenames below; they are referenced by [`../../QUICKSTART-GKE-LIVE.md`](../../QUICKSTART-GKE-LIVE.md)
and the Medium article.

| File | Capture point | What it shows |
|------|---------------|---------------|
| `01-horizon-login.png` | Horizon `/auth/login/` | "Authenticate using: Login with Keycloak" + Sign In |
| `02-keycloak-github.png` | Keycloak `.../realms/krateo/protocol/openid-connect/auth` | "KRATEO SSO" page with the **GitHub** broker button |
| `03-github-authorize.png` | `github.com/login/oauth/authorize` | GitHub OAuth App authorization consent |
| `04-horizon-demo.png` | Horizon `/project/api_access/` | Logged in as `braghettos`, scoped to **`keycloak • demo`** |

Optional: `sso-flow.gif` — the whole click-through as an animation.
