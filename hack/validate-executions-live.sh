#!/usr/bin/env bash
# Live validation of the KeycloakAuthenticationExecution reconcile semantics
# against a REAL Keycloak - no cluster required.
#
# What it does:
#   1. `helm template`s the chart and extracts the EXACT jq programs from the
#      rendered RESTActions + RestDefinition (observe filter, notFoundExpr,
#      upToDateExpr, create payload, update/delete stage iterators+payloads).
#   2. Replays rest-dynamic-controller's level-based reconcile loop and
#      snowplow's stage semantics (extras-seeded dict, dependsOn ordering,
#      iterator = one call per element templated against the item only,
#      continueOnError) with curl + jq against a live Keycloak.
#   3. Builds the FULL step-up ladder from samples/20-authentication-mfa.yaml,
#      asserts structure convergence, then injects requirement / priority /
#      config drift and a subflow-recreate, asserting re-convergence, and
#      finally validates finalizer-style deletion (single-exec GET -> 404).
#
# Prereqs: docker-run Keycloak (or any reachable one), helm, jq, python3+pyyaml.
#   docker run -d --name kc-exec-validate -p 8081:8080 \
#     -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
#     quay.io/keycloak/keycloak:26.0 start-dev
#   # then (HTTP from the docker gateway counts as "external" for the master realm):
#   docker exec kc-exec-validate /opt/keycloak/bin/kcadm.sh config credentials \
#     --server http://localhost:8080 --realm master --user admin --password admin
#   docker exec kc-exec-validate /opt/keycloak/bin/kcadm.sh update realms/master -s sslRequired=NONE
#
# Env: KC_URL (default http://localhost:8081), KC_ADMIN/KC_ADMIN_PASS (admin/admin),
#      REALM (kog-exec-validate).
set -euo pipefail
cd "$(dirname "$0")/.."

export KC_URL="${KC_URL:-http://localhost:8081}"
export KC_ADMIN="${KC_ADMIN:-admin}"
export KC_ADMIN_PASS="${KC_ADMIN_PASS:-admin}"
export REALM="${REALM:-kog-exec-validate}"

command -v helm >/dev/null || { echo "helm required"; exit 1; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

helm template kog-validate chart --namespace kog-validate > /tmp/kog-exec-rendered.yaml

python3 - <<'PYEOF'
import json, os, re, subprocess, sys, urllib.request, urllib.error, urllib.parse
import yaml

KC = os.environ["KC_URL"].rstrip("/")
REALM = os.environ["REALM"]
PASSES_CAP = 10

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def http(method, path, body=None, token=[None]):
    if token[0] is None:
        data = urllib.parse.urlencode({
            "grant_type": "password", "client_id": "admin-cli",
            "username": os.environ["KC_ADMIN"], "password": os.environ["KC_ADMIN_PASS"],
        }).encode()
        req = urllib.request.Request(f"{KC}/realms/master/protocol/openid-connect/token", data=data)
        token[0] = json.load(urllib.request.urlopen(req))["access_token"]
    req = urllib.request.Request(KC + path, method=method)
    req.add_header("Authorization", "Bearer " + token[0])
    payload = None
    if body is not None:
        payload = json.dumps(body).encode()
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, payload) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw.strip() else None)
    except urllib.error.HTTPError as e:
        return e.code, None

def jq(program, data, *, raw_path=False):
    """Evaluate a jq program exactly as authored in the manifests."""
    p = subprocess.run(["jq", "-c", program], input=json.dumps(data),
                       capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"jq failed: {p.stderr}\nprogram: {program[:200]}")
    return json.loads(p.stdout)

def unwrap(tpl):
    """snowplow `${ ... }` template -> inner jq program."""
    m = re.search(r"\$\{(.*)\}\s*$", tpl.strip(), re.S)
    assert m, f"not a template: {tpl[:80]}"
    return m.group(1).strip()

FAILS = []
def check(desc, cond):
    print(("  ok   " if cond else "  FAIL ") + desc)
    if not cond:
        FAILS.append(desc)

# ---------------------------------------------------------------------------
# 1. extract the EXACT programs from the rendered manifests
# ---------------------------------------------------------------------------
docs = [d for d in yaml.safe_load_all(open("/tmp/kog-exec-rendered.yaml")) if d]
ras = {d["metadata"]["name"].split("-authenticationexecution-")[-1]: d
       for d in docs if d.get("kind") == "RESTAction" and "authenticationexecution" in d["metadata"]["name"]}
rd = next(d for d in docs if d.get("kind") == "RestDefinition"
          and d["metadata"]["name"].endswith("authenticationexecution"))
res = rd["spec"]["resource"]
NOT_FOUND = res["observeApiRef"]["notFoundExpr"]["inline"]
UP_TO_DATE = res["observeApiRef"]["upToDateExpr"]["inline"]
IDENTIFIERS = res["identifiers"]
OBSERVE_FILTER = ras["observe"]["spec"]["filter"]
CREATE_STAGES = ras["create"]["spec"]["api"]
UPDATE_STAGES = ras["update"]["spec"]["api"]
DELETE_STAGES = ras["delete"]["spec"]["api"]
GET_VERB = next(v for v in res["verbsDescription"] if v["action"] == "get")
print(f"extracted: observe filter, predicates, {len(CREATE_STAGES)} create stages, {len(UPDATE_STAGES)} update stages, "
      f"{len(DELETE_STAGES)} delete stages, get verb {GET_VERB['path']}")

# ---------------------------------------------------------------------------
# 2. faithful engine: rdc buildExtras + snowplow stage semantics
# ---------------------------------------------------------------------------
def build_extras(cr, include_spec):
    extras = {"name": cr["metadata"]["name"], "namespace": "kog-validate", "uid": "sim"}
    for ident in IDENTIFIERS:                       # spec-first, omit when absent
        if ident in cr["spec"]:
            extras[ident] = cr["spec"][ident]
    if include_spec:
        extras["spec"] = cr["spec"]
    return extras

def run_stage(stage, dict_):
    """One snowplow api[] stage against Keycloak. Mutates dict_ (stage output under its name)."""
    verb = stage.get("verb", "GET")
    iterator = (stage.get("dependsOn") or {}).get("iterator")
    items = jq(iterator, dict_) if iterator else [dict_]
    if iterator and not isinstance(items, list):
        raise RuntimeError("iterator must yield array")
    out = []
    for item in items:                              # iterated: template vs ITEM ONLY
        ctx = item
        path = jq(unwrap(stage["path"]), ctx)
        body = None
        if "payload" in stage:
            body = jq(unwrap(stage["payload"]), ctx)
        code, resp = http(verb, path, body)
        ok = code < 300
        if not ok and not stage.get("continueOnError"):
            return False                            # snowplow: truncate downstream stages
        if ok and resp is not None:
            out.append(resp)
    if not iterator and out:
        dict_[stage["name"]] = out[0]
    return True

def observe(cr):
    dict_ = build_extras(cr, include_spec=False)
    run_stage(ras["observe"]["spec"]["api"][0], dict_)   # 404-tolerant list
    status = jq(OBSERVE_FILTER, dict_)
    pred = {"spec": cr["spec"], "status": status}
    not_found = jq(NOT_FOUND, pred)
    up_to_date = True if not_found else jq(UP_TO_DATE, pred)
    return status, not_found, up_to_date

def mutate(kind, cr):
    dict_ = build_extras(cr, include_spec=True)
    stages = {"create": CREATE_STAGES, "update": UPDATE_STAGES, "delete": DELETE_STAGES}[kind]
    for st in stages:
        if not run_stage(st, dict_):
            break                                   # truncated chain

def reconcile_all(crs, passes=PASSES_CAP):
    """rdc level-based loop: observe -> create|update until all up-to-date."""
    for p in range(1, passes + 1):
        pending = 0
        for cr in crs:
            status, not_found, utd = observe(cr)
            if not_found:
                mutate("create", cr); pending += 1
            elif not utd:
                mutate("update", cr); pending += 1
        if pending == 0:
            return p
    return None

# ---------------------------------------------------------------------------
# 3. the sample's execution CRs + realm/flow scaffolding
# ---------------------------------------------------------------------------
sample = [d for d in yaml.safe_load_all(open("samples/20-authentication-mfa.yaml")) if d]
crs = [d for d in sample if d.get("kind") == "KeycloakAuthenticationExecution"]
for cr in crs:
    cr["spec"]["realm"] = REALM        # retarget the sample realm to the throwaway one
flow_cr = next(d for d in sample if d.get("kind") == "KeycloakAuthenticationFlow")
print(f"sample: {len(crs)} execution CRs, ladder flow '{flow_cr['spec']['alias']}'")

http("DELETE", f"/admin/realms/{REALM}")
code, _ = http("POST", "/admin/realms", {"realm": REALM, "enabled": True, "sslRequired": "none"})
assert code == 201, f"realm create {code}"
code, _ = http("POST", f"/admin/realms/{REALM}/authentication/flows", {
    "alias": flow_cr["spec"]["alias"], "providerId": "basic-flow",
    "topLevel": True, "builtIn": False, "description": "validation ladder"})
assert code == 201, f"flow create {code}"

def listing(alias):
    _, resp = http("GET", f"/admin/realms/{REALM}/authentication/flows/{alias}/executions")
    return resp or []

def snapshot():
    return {e["displayName"]: e for e in listing(flow_cr["spec"]["alias"])}

# ---------------------------------------------------------------------------
# 4. converge the ladder from scratch
# ---------------------------------------------------------------------------
print("\n== build: converge the full step-up ladder ==")
p = reconcile_all(crs)
check(f"ladder converged (in {p} passes)", p is not None)

top = listing(flow_cr["spec"]["alias"])
order0 = [e["displayName"] for e in top if e["level"] == 0]
check(f"level-0 order by priority {order0}",
      order0 == ["Cookie", "Identity Provider Redirector", "browser-mfa-forms"])
reqs = {e["displayName"]: e["requirement"] for e in top}
check("requirements converged",
      reqs.get("Cookie") == "ALTERNATIVE" and reqs.get("browser-mfa-forms") == "ALTERNATIVE"
      and reqs.get("browser-mfa-loa1") == "CONDITIONAL" and reqs.get("browser-mfa-loa2") == "CONDITIONAL"
      and reqs.get("OTP Form") == "REQUIRED")
conds = [e for e in top if e.get("providerId") == "conditional-level-of-authentication"] if top else []
check("both LoA conditions have config attached",
      len(conds) == 2 and all(e.get("authenticationConfig") for e in conds))
cfgs = {}
for e in conds:
    _, cfg = http("GET", f"/admin/realms/{REALM}/authentication/config/{e['authenticationConfig']}")
    cfgs[cfg["alias"]] = cfg["config"]
check("LoA condition config values applied",
      cfgs.get("loa1-condition", {}).get("loa-condition-level") == "1"
      and cfgs.get("loa2-condition", {}).get("loa-condition-level") == "2")

# ---------------------------------------------------------------------------
# 5. drift injections
# ---------------------------------------------------------------------------
print("\n== drift: requirement flipped out-of-band ==")
cookie = snapshot()["Cookie"]
cookie["requirement"] = "DISABLED"
http("PUT", f"/admin/realms/{REALM}/authentication/flows/{flow_cr['spec']['alias']}/executions", cookie)
p = reconcile_all(crs)
check(f"requirement drift re-converged (in {p} passes)",
      p is not None and snapshot()["Cookie"]["requirement"] == "ALTERNATIVE")

print("\n== drift: spec.priority change on an execution (recreate path) ==")
idp = next(c for c in crs if c["spec"].get("provider") == "identity-provider-redirector")
idp["spec"]["priority"] = 5          # was 20 -> should now sort BEFORE Cookie (10)
p = reconcile_all(crs)
new_order = [e["displayName"] for e in listing(flow_cr["spec"]["alias"]) if e["level"] == 0]
check(f"priority drift re-converged via recreate (in {p} passes): {new_order}",
      p is not None and new_order == ["Identity Provider Redirector", "Cookie", "browser-mfa-forms"])
check("recreated execution requirement restored",
      snapshot()["Identity Provider Redirector"]["requirement"] == "ALTERNATIVE")

print("\n== drift: authenticator config detached out-of-band ==")
loa2cond = next(e for e in listing("browser-mfa-loa2") if e.get("providerId") == "conditional-level-of-authentication")
http("DELETE", f"/admin/realms/{REALM}/authentication/config/{loa2cond['authenticationConfig']}")
p = reconcile_all(crs)
loa2cond = next(e for e in listing("browser-mfa-loa2") if e.get("providerId") == "conditional-level-of-authentication")
check(f"config presence drift re-converged (in {p} passes)",
      p is not None and loa2cond.get("authenticationConfig"))

print("\n== drift: subflow priority change (recreate deletes children; CRs self-heal) ==")
loa2 = next(c for c in crs if c["spec"].get("alias") == "browser-mfa-loa2")
loa2["spec"]["priority"] = 15        # forces subflow delete+recreate -> children vanish
p = reconcile_all(crs)
loa2kids = listing("browser-mfa-loa2")
check(f"subflow recreated AND children self-healed (in {p} passes)",
      p is not None and len(loa2kids) == 2
      and {e.get("providerId") for e in loa2kids} == {"conditional-level-of-authentication", "auth-otp-form"}
      and all(e["requirement"] == "REQUIRED" for e in loa2kids))

print("\n== safety: spurious create on an EXISTING execution must not duplicate ==")
cookie_cr = next(c for c in crs if c["spec"].get("provider") == "auth-cookie")
before = len([e for e in listing(flow_cr["spec"]["alias"]) if e["level"] == 0])
mutate("create", cookie_cr)          # simulate rdc firing create on a spurious notFound
after = len([e for e in listing(flow_cr["spec"]["alias"]) if e["level"] == 0])
check(f"self-gated create did not duplicate (level-0 count {before} -> {after})", before == after)

# ---------------------------------------------------------------------------
# 6. delete + finalizer-style verification (the RestDefinition's get verb)
# ---------------------------------------------------------------------------
print("\n== delete: RESTAction + get-verb 404 verification ==")
otp = next(c for c in crs if c["spec"].get("provider") == "auth-otp-form")
status, _, _ = observe(otp)
exec_id = status.get("id")
mutate("delete", otp)
get_path = GET_VERB["path"].replace("{realm}", REALM).replace("{executionId}", exec_id or "")
code, _ = http("GET", get_path)
check(f"single-exec GET after delete -> {code} (finalizer released only on 404)", code == 404)
status, not_found, _ = observe(otp)
check("observe agrees the execution is gone (notFound -> would re-create)", not_found)

print()
if FAILS:
    print(f"VALIDATION FAILED: {len(FAILS)} assertion(s):"); [print("  -", f) for f in FAILS]
    sys.exit(1)
print("ALL VALIDATIONS PASSED against " + KC)
PYEOF
