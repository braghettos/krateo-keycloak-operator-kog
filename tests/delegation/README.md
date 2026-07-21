# Delegation-wiring static tests

`KeycloakAuthenticationExecution` delegates its four lifecycle verbs to Snowplow
`RESTAction`s (`observeApiRef`/`createApiRef`/`updateApiRef`/`deleteApiRef`, see
`chart/templates/restactions-authenticationexecution.yaml`). The behaviour of
that delegation lives entirely in **jq programs** — the observe `filter`, the
`notFoundExpr`/`upToDateExpr` predicates, and the per-stage `dependsOn.iterator`
fan-outs.

`run.py` proves those programs statically:

1. `helm template`s the chart and **extracts the exact jq from the rendered
   manifests** — nothing is duplicated into the test, so it always tracks what
   the chart actually ships.
2. Evaluates each program with `jq` against the fixture payloads in `fixtures/`
   (a realistic Keycloak flow-executions listing modelled on the sample ladder).

It asserts the four wiring behaviours called out in review:

| Area | Assertion |
|------|-----------|
| **observe select/compose** | picks the level-0 entry by `providerId` (execution) or `authenticationFlow`+`displayName` (subflow); composes `{found,id,requirement,index,level,priority,configured}`; a 404/empty listing composes `{found:false}` |
| **create fan-out** | self-gating iterator emits exactly one POST body when absent (right verb-kind + native `priority`), **empty** when the execution already exists |
| **move-list fan-out** | priority-drift `pdel`+`pcreate` emit a delete-by-id then recreate-with-desired-priority pair only on real drift; `requirement` PUT echoes the matched entry; config stages are presence-gated |
| **delete iterator** | emits `[{realm,id}]` when present, `[]` when the parent flow is gone (the no-op that releases the finalizer) |

## Run

```bash
python3 tests/delegation/run.py     # needs helm, jq, python3 + pyyaml
```

Fully offline — **no Keycloak, no cluster**. The complementary
`hack/validate-executions-live.sh` replays the same extracted programs against a
**real Keycloak** (still not an in-cluster reconcile through oasgen+rdc+snowplow,
which is a separately-gated live step). Wired into CI via
`.github/workflows/chart-tests.yaml`.
