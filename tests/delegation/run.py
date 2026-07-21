#!/usr/bin/env python3
# Static tests for the KeycloakAuthenticationExecution DELEGATION WIRING.
#
# These assert the jq programs of the four Snowplow RESTActions
# (observe / create / update / delete) that the RestDefinition delegates its
# lifecycle verbs to. Unlike hack/validate-executions-live.sh (which needs a
# real Keycloak), this runs FULLY OFFLINE: it renders the chart, extracts the
# EXACT jq from the rendered manifests, and evaluates it with `jq` against
# hand-authored fixture payloads. So it proves the *shipped* filters compose
# and fan out as claimed, with nothing duplicated into the test.
#
# What is asserted (the four wiring behaviours called out in review):
#   1. observe select/compose  — the observe filter picks the level-0 entry by
#      provider (execution) / displayName (subflow) and composes
#      {found,id,requirement,index,level,priority,configured}; a 404/empty
#      listing composes {found:false}.
#   2. create fan-out (self-gating) — the create iterator emits exactly ONE POST
#      body when the execution is absent (correct verb-kind + priority), and an
#      EMPTY array when it already exists (a spurious observe cannot duplicate).
#   3. move-list fan-out — the update priority-drift stages (pdel + pcreate)
#      iterate the SAME snapshot and emit a delete+recreate pair ONLY on real
#      priority drift, and nothing when priority already matches.
#   4. delete iterator — emits [{realm,id}] when the entry is present and [] when
#      the parent flow is gone (the no-op that releases the finalizer).
#
# Plus: the RestDefinition predicates (notFoundExpr / upToDateExpr) fire on the
# composed observe status exactly as the reconcile loop expects.
#
# Prereqs: helm, jq, python3 (+pyyaml). Exit 0 = all green.
import json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
CHART = os.path.join(REPO, "chart")
FIXTURES = os.path.join(HERE, "fixtures")

try:
    import yaml
except ImportError:
    sys.exit("PyYAML required: pip install pyyaml")


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def jq(program, data):
    """Evaluate a jq program exactly as authored in the manifests."""
    p = sh(["jq", "-c", program], input=json.dumps(data))
    if p.returncode != 0:
        raise RuntimeError(f"jq failed: {p.stderr}\nprogram:\n{program}")
    return json.loads(p.stdout)


def unwrap(tpl):
    """snowplow `${ ... }` path/payload template -> inner jq program."""
    m = re.search(r"\$\{(.*)\}\s*$", tpl.strip(), re.S)
    assert m, f"not a template: {tpl[:80]}"
    return m.group(1).strip()


FAILS = []


def check(desc, cond, got=None):
    print(("  ok   " if cond else "  FAIL ") + desc + ("" if cond or got is None else f"  (got: {got})"))
    if not cond:
        FAILS.append(desc)


# ---------------------------------------------------------------------------
# 0. render the chart and extract the EXACT programs (no jq duplicated here)
# ---------------------------------------------------------------------------
r = sh(["helm", "template", "kog", CHART, "--namespace", "kogns"])
if r.returncode != 0:
    sys.exit("helm template failed:\n" + r.stderr)
docs = [d for d in yaml.safe_load_all(r.stdout) if d]

ras = {d["metadata"]["name"].split("-authenticationexecution-")[-1]: d
       for d in docs if d.get("kind") == "RESTAction"
       and "authenticationexecution" in d["metadata"]["name"]}
missing = {"observe", "create", "update", "delete"} - set(ras)
if missing:
    sys.exit(f"rendered chart missing RESTActions: {missing}")

rd = next(d for d in docs if d.get("kind") == "RestDefinition"
          and d["metadata"]["name"].endswith("authenticationexecution"))
res = rd["spec"]["resource"]
NOT_FOUND = res["observeApiRef"]["notFoundExpr"]["inline"]
UP_TO_DATE = res["observeApiRef"]["upToDateExpr"]["inline"]
IDENTIFIERS = res["identifiers"]

OBSERVE_FILTER = ras["observe"]["spec"]["filter"]
CREATE_STAGES = {s["name"]: s for s in ras["create"]["spec"]["api"]}
UPDATE_STAGES = {s["name"]: s for s in ras["update"]["spec"]["api"]}
DELETE_STAGES = {s["name"]: s for s in ras["delete"]["spec"]["api"]}

print(f"extracted from rendered chart: observe filter, "
      f"{len(CREATE_STAGES)} create / {len(UPDATE_STAGES)} update / {len(DELETE_STAGES)} delete stages, "
      f"identifiers={IDENTIFIERS}")

LISTING = json.load(open(os.path.join(FIXTURES, "flow-executions.json")))


# ---------------------------------------------------------------------------
# rdc extras: identifiers resolved from spec (spec-first, omit-when-absent),
# +spec for create/update. The observe/list stages receive the listing under
# the api[] stage name ("executions" for observe; "list" for the mutations).
# ---------------------------------------------------------------------------
def extras(spec, include_spec):
    e = {"name": "cr-" + spec.get("provider", spec.get("alias", "x")), "namespace": "kogns"}
    for ident in IDENTIFIERS:
        if ident in spec:
            e[ident] = spec[ident]
    if include_spec:
        e["spec"] = spec
    return e


def observe(spec, listing):
    d = extras(spec, include_spec=False)
    d["executions"] = listing              # 404-tolerant list stage output
    return jq(OBSERVE_FILTER, d)


def iterate(stage, spec, listing):
    """Run a mutation stage's dependsOn.iterator against the `list` snapshot."""
    d = extras(spec, include_spec=True)
    d["list"] = listing
    return jq(stage["dependsOn"]["iterator"], d)


# spec fixtures drawn from samples/20-authentication-mfa.yaml
COOKIE = {"realm": "mfa-demo", "flowAlias": "browser-mfa", "provider": "auth-cookie",
          "requirement": "ALTERNATIVE", "priority": 10}
FORMS = {"realm": "mfa-demo", "flowAlias": "browser-mfa", "subFlow": True,
         "alias": "browser-mfa-forms", "description": "Interactive forms (LoA ladder)",
         "requirement": "ALTERNATIVE", "priority": 30}
LOA2COND = {"realm": "mfa-demo", "flowAlias": "browser-mfa-loa2",
            "provider": "conditional-level-of-authentication", "requirement": "REQUIRED",
            "priority": 10, "configAlias": "loa2-condition",
            "config": {"loa-condition-level": "2", "loa-max-age": "0"}}


# ===========================================================================
# 1. OBSERVE — select the right level-0 entry and COMPOSE the status
# ===========================================================================
print("\n== observe: select level-0 entry + compose status ==")

s = observe(COOKIE, LISTING)
check("execution match composes found+id+requirement+priority",
      s == {"found": True, "id": "exec-cookie", "requirement": "ALTERNATIVE",
            "index": 0, "level": 0, "priority": 10, "configured": False}, s)

s = observe(FORMS, LISTING)
check("subflow matched by authenticationFlow+displayName (not providerId)",
      s.get("found") and s.get("id") == "flow-forms" and s.get("priority") == 30, s)

# a conditional-level-of-authentication execution lives at level>0 inside the
# browser-mfa listing but is level-0 within ITS OWN parent's listing — observe
# is always called with the parent flow (flowAlias) listing, so re-list under
# the loa2 subflow: only the two loa2 children are level-0 there.
LOA2_LISTING = [dict(e, level=0, index=i) for i, e in enumerate(
    e for e in LISTING if e["id"] in ("exec-loa2-condition", "exec-loa2-otp"))]
s = observe(LOA2COND, LOA2_LISTING)
check("configured=true when authenticationConfig is attached",
      s.get("found") and s.get("configured") is True and s.get("id") == "exec-loa2-condition", s)

# selection must ignore deeper-level rows that happen to share a providerId
DUP = LISTING + [{"id": "deep-cookie", "providerId": "auth-cookie", "level": 2,
                  "index": 9, "priority": 99, "requirement": "REQUIRED"}]
s = observe(COOKIE, DUP)
check("deeper-level row with same providerId is NOT selected (level-0 only)",
      s.get("id") == "exec-cookie", s)

# 404 / empty parent-flow listing composes {found:false} (create-gating)
s = observe(COOKIE, [])
check("empty listing composes {found:false}", s == {"found": False}, s)

# a provider not present composes {found:false}
s = observe({"realm": "mfa-demo", "flowAlias": "browser-mfa", "provider": "nope"}, LISTING)
check("absent provider composes {found:false}", s == {"found": False}, s)


# ===========================================================================
# 2. PREDICATES on the composed status (notFoundExpr / upToDateExpr)
# ===========================================================================
print("\n== predicates: notFoundExpr / upToDateExpr over composed status ==")


def not_found(spec, status):
    return jq(NOT_FOUND, {"spec": spec, "status": status})


def up_to_date(spec, status):
    return jq(UP_TO_DATE, {"spec": spec, "status": status})


check("notFound=true when status.found is false",
      not_found(COOKIE, {"found": False}) is True)
check("notFound=false when status.found is true",
      not_found(COOKIE, observe(COOKIE, LISTING)) is False)
check("upToDate=true when requirement+priority match and no config wanted",
      up_to_date(COOKIE, observe(COOKIE, LISTING)) is True)
check("upToDate=false on requirement drift",
      up_to_date(dict(COOKIE, requirement="REQUIRED"), observe(COOKIE, LISTING)) is False)
check("upToDate=false on priority drift",
      up_to_date(dict(COOKIE, priority=99), observe(COOKIE, LISTING)) is False)
check("upToDate=false when config declared but not attached (presence-only)",
      up_to_date(dict(COOKIE, config={"x": "y"}), observe(COOKIE, LISTING)) is False)


# ===========================================================================
# 3. CREATE fan-out — self-gating: 1 body when absent, [] when present
# ===========================================================================
print("\n== create: self-gated iterator fan-out ==")

# execution absent from the listing -> exactly one POST body
absent = [e for e in LISTING if e.get("providerId") != "auth-cookie"]
items = iterate(CREATE_STAGES["create"], COOKIE, absent)
check("absent execution -> exactly one create item", len(items) == 1, items)
if items:
    it = items[0]
    check("create item targets .../executions/execution (kind=execution)", it.get("kind") == "execution", it.get("kind"))
    check("create body carries provider + native priority",
          it.get("body") == {"provider": "auth-cookie", "priority": 10}, it.get("body"))
    # path template resolves against the item
    path = jq(unwrap(CREATE_STAGES["create"]["path"]), it)
    check("create path = /admin/realms/mfa-demo/authentication/flows/browser-mfa/executions/execution",
          path == "/admin/realms/mfa-demo/authentication/flows/browser-mfa/executions/execution", path)

# subflow absent -> flow body with alias/type/description/priority
absent_sub = [e for e in LISTING if e.get("displayName") != "browser-mfa-forms"]
items = iterate(CREATE_STAGES["create"], FORMS, absent_sub)
check("absent subflow -> exactly one create item", len(items) == 1, items)
if items:
    it = items[0]
    check("subflow create targets .../executions/flow (kind=flow)", it.get("kind") == "flow", it.get("kind"))
    check("subflow body = {alias,type=basic-flow,description,priority}",
          it.get("body") == {"alias": "browser-mfa-forms", "type": "basic-flow",
                             "description": "Interactive forms (LoA ladder)", "priority": 30},
          it.get("body"))

# SELF-GATING: execution ALREADY present -> empty iterator (no duplicate POST)
items = iterate(CREATE_STAGES["create"], COOKIE, LISTING)
check("present execution -> EMPTY create iterator (self-gating, no duplicate)", items == [], items)
items = iterate(CREATE_STAGES["create"], FORMS, LISTING)
check("present subflow -> EMPTY create iterator", items == [], items)


# ===========================================================================
# 4. MOVE-LIST fan-out — priority-drift delete+recreate (pdel / pcreate)
# ===========================================================================
print("\n== update: priority-drift move-list fan-out (pdel + pcreate) ==")

# no drift: priority already matches the listing -> both stages emit nothing
pdel = iterate(UPDATE_STAGES["pdel"], COOKIE, LISTING)
pcreate = iterate(UPDATE_STAGES["pcreate"], COOKIE, LISTING)
check("no priority drift -> pdel empty", pdel == [], pdel)
check("no priority drift -> pcreate empty", pcreate == [], pcreate)

# drift: spec wants priority 5, listing has 10 -> delete-by-id THEN recreate
DRIFT = dict(COOKIE, priority=5)
pdel = iterate(UPDATE_STAGES["pdel"], DRIFT, LISTING)
pcreate = iterate(UPDATE_STAGES["pcreate"], DRIFT, LISTING)
check("priority drift -> pdel deletes the current entry by id",
      len(pdel) == 1 and pdel[0].get("id") == "exec-cookie", pdel)
check("priority drift -> pcreate re-creates with the DESIRED priority",
      len(pcreate) == 1 and pcreate[0].get("body") == {"provider": "auth-cookie", "priority": 5},
      pcreate)
if pdel:
    dpath = jq(unwrap(UPDATE_STAGES["pdel"]["path"]), pdel[0])
    check("pdel path = /admin/realms/mfa-demo/authentication/executions/exec-cookie",
          dpath == "/admin/realms/mfa-demo/authentication/executions/exec-cookie", dpath)

# requirement PUT stage: matched entry echoed back with desired requirement
d = extras(dict(COOKIE, requirement="REQUIRED"), include_spec=True)
d["list"] = LISTING
req_body = jq(unwrap(UPDATE_STAGES["requirement"]["payload"]), d)
check("requirement stage PUTs the matched entry with spec.requirement",
      req_body.get("id") == "exec-cookie" and req_body.get("requirement") == "REQUIRED", req_body)

# config presence gating: create-config only when none attached
cfg_items = iterate(UPDATE_STAGES["configcreate"], LOA2COND, LOA2_LISTING)
check("configcreate is EMPTY when config already attached (presence-gated)",
      cfg_items == [], cfg_items)
DETACHED = [dict(e) for e in LOA2_LISTING]
for e in DETACHED:
    e.pop("authenticationConfig", None)
cfg_items = iterate(UPDATE_STAGES["configcreate"], LOA2COND, DETACHED)
check("configcreate emits one POST when config declared but not attached",
      len(cfg_items) == 1 and cfg_items[0].get("config") == {"loa-condition-level": "2", "loa-max-age": "0"}
      and cfg_items[0].get("alias") == "loa2-condition", cfg_items)


# ===========================================================================
# 5. DELETE iterator — [{realm,id}] when present, [] when flow is gone
# ===========================================================================
print("\n== delete: iterator (found -> delete-by-id; gone -> no-op) ==")

items = iterate(DELETE_STAGES["del"], COOKIE, LISTING)
check("present entry -> delete-by-id emitted",
      len(items) == 1 and items[0].get("id") == "exec-cookie" and items[0].get("realm") == "mfa-demo",
      items)
if items:
    dpath = jq(unwrap(DELETE_STAGES["del"]["path"]), items[0])
    check("delete path = /admin/realms/mfa-demo/authentication/executions/exec-cookie",
          dpath == "/admin/realms/mfa-demo/authentication/executions/exec-cookie", dpath)

# parent flow already gone -> list stage 404s (continueOnError) -> .list absent
d = extras(COOKIE, include_spec=True)   # no .list key at all (404-tolerant listError)
items = jq(DELETE_STAGES["del"]["dependsOn"]["iterator"], d)
check("parent flow gone (no listing) -> EMPTY delete iterator (finalizer released as no-op)",
      items == [], items)

# subflow delete matched by alias
items = iterate(DELETE_STAGES["del"], FORMS, LISTING)
check("subflow delete matched by alias -> delete-by-id",
      len(items) == 1 and items[0].get("id") == "flow-forms", items)


# ---------------------------------------------------------------------------
print()
if FAILS:
    print(f"DELEGATION WIRING TESTS FAILED: {len(FAILS)} assertion(s):")
    for f in FAILS:
        print("  -", f)
    sys.exit(1)
print("ALL DELEGATION WIRING TESTS PASSED")
