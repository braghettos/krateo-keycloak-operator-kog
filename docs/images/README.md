# Screenshots for the live GKE walkthrough

Captured live on GKE cluster `osh-sso` while validating the
GitHub → Keycloak → Keystone → Horizon SSO chain (federated user `braghettos`
auto-provisioned into the `demo` project). Referenced by
[`../../QUICKSTART-GKE-LIVE.md`](../../QUICKSTART-GKE-LIVE.md) and the Medium article.

| File | Capture point | What it shows |
|------|---------------|---------------|
| `01-horizon-login.png` | Horizon `/auth/login/` | "Authenticate using: Login with Keycloak" + Sign In |
| `02-keycloak-github.png` | Keycloak `.../realms/krateo/...auth` | "KRATEO SSO" page with the **GitHub** broker button |
| `04-horizon-demo.png` | Horizon `/project/api_access/` | Logged in as `braghettos`, scoped to **`keycloak • demo`** |

`03-github-authorize.png` (the GitHub OAuth consent) is intentionally omitted: GitHub
shows it **only on first login** and remembers the grant thereafter, so it can't be
re-captured without revoking the app authorization.

These are true, pixel-perfect captures of the live browser (`02` shows the Keycloak
page forced with `prompt=login`, hence the pre-filled user and re-authenticate note).
