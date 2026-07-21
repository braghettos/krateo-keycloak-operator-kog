# acr=2 traced through the CRs this PR ships

This demo closes a gap between the sample and the existing `demo/mfa-stepup`.

| | `demo/mfa-stepup` | **this demo (`acr-via-crs`)** |
|---|---|---|
| How the LoA ladder is built | **imperatively** — `kcadm` scripts (`31-loa-flow.sh` / `32-loa-wire.sh`) | **`kubectl apply`** of `samples/20-authentication-mfa.yaml` — the `KeycloakAuthenticationExecution` CRs, reconciled by the control plane |
| Client | `kubernetes` (public), `acr_values=2` | `acr-app` (confidential) with `acr.loa.map` `{silver:1,gold:2}`, `acr_values=gold` |
| What it proves | the **admission gate** consumes `acr` | the **CRs this PR ships** actually produce a ladder that issues `acr=2` |
| Flow alias | `mfa-browser` | `browser-mfa` (the sample's) |

`demo/mfa-stepup` is still the right place to see the *Kubernetes admission
gate* end to end; it just wires Keycloak by hand. This demo is the traceable
link from **the sample CRs → an `acr=2` token**, using the matching client and
`acr_values` so the story is reproducible from the artifacts the PR adds.

## This requires a LIVE cluster + control plane

Applying `KeycloakAuthenticationExecution` CRs means the Krateo control plane
(oasgen-provider + rest-dynamic-controller + snowplow) reconciles them into
Keycloak. That is the **separately-gated live-reconcile step** — it is *not*
proven by the static tests (`tests/delegation`) or the live-Keycloak replay
(`hack/validate-executions-live.sh`, which talks to Keycloak directly, bypassing
the controllers). This demo is the executable script for that step, with
explicit preconditions rather than prose.

### Preconditions

1. **Cluster + chart installed**, snowplow + authn wired into the rdc
   deployment (see `docs/ARCHITECTURE.md` → *Deployment prerequisites*), and:
   ```bash
   kubectl -n krateo-system wait --for=condition=Ready restdefinition --all --timeout=5m
   ```
2. **Keycloak reachable** both in-cluster (controllers) and from your shell
   (`KC_URL`, for minting).
3. **Admin-token Secret** present (ESO-managed or manual) so the Configuration
   CRs authenticate.
4. **The `acr-app` client secret.** `acr-app` is confidential; read the secret
   Keycloak generated (`kubectl get secret` / admin console) into `CLIENT_SECRET`.
5. **A test user with password + TOTP** in `mfa-demo` (LoA-2 is OTP):
   ```bash
   TOTP_SECRET=MYRAWTOTPSECRET123 bash demo/acr-via-crs/seed-user-otp.sh
   ```

## Run

```bash
export KC_URL=https://keycloak.example        # reachable from your shell
export CLIENT_SECRET=<acr-app client secret>
export TOTP_SECRET=MYRAWTOTPSECRET123          # same value passed to the seeder
export REDIRECT_URI=https://app.example/*      # a redirect URI registered on acr-app

bash demo/acr-via-crs/apply-and-mint.sh
```

The script:

1. `kubectl apply`s `samples/00-configurations.yaml` + `samples/20-authentication-mfa.yaml`;
2. `kubectl wait`s the `KeycloakAuthenticationExecution` CRs to `Ready` (the
   control plane building the ladder in Keycloak — the live reconcile);
3. patches the realm CR to **bind `browser-mfa`** as the browser flow (the
   sample leaves it unbound so a first apply cannot race the flow's creation);
4. runs the interactive login `acr_values=gold` → password → **TOTP step-up** →
   auth-code exchange, and **asserts the id_token carries `acr=2`**.

`APPLY=0 bash demo/acr-via-crs/apply-and-mint.sh` skips the apply/wait and only
mints against an already-converged ladder.

> Direct-grant (`grant_type=password`) can *not* be used here: the conditional
> step-up and `auth_time` only exist on the browser flow, so the script drives
> the auth-code flow — the same shape a real CMP portal uses when it redirects
> with `acr_values=gold`.
