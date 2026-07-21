#!/usr/bin/env python3
"""Generate KOG-friendly OpenAPI 3.0 subsets for the Keycloak Admin API resources.

Each emitted asset:
  * declares the `bearer` (http/bearer) securityScheme that the upstream
    Keycloak OAS omits (KOG only accepts http/basic and http/bearer);
  * keeps a curated, SSO-relevant subset of the upstream *Representation
    schemas (the full RealmRepresentation has 152 fields and would blow up
    the generated CRD);
  * exposes a clean collection (POST/GET) + item (GET/PUT/DELETE) shape so
    rest-dynamic-controller can reconcile it.

Field names are taken verbatim from the official Keycloak OAS 3.0.3
(components.schemas.*Representation) so request bodies stay wire-compatible.
"""
import collections, yaml

# str/object map used by Keycloak for free-form config (Map<String,String>)
STRMAP = {"type": "object", "additionalProperties": {"type": "string"}}
STRARR = {"type": "array", "items": {"type": "string"}}

def prop(t, desc=None, **extra):
    p = {"type": t} if t else {}
    if desc: p["description"] = desc
    p.update(extra)
    return p

# ---- curated schemas (subset of the upstream *Representation) ---------------
SCHEMAS = {
    "realm": ("RealmRepresentation", {
        "realm": prop("string", "Realm name. Immutable natural key."),
        "enabled": prop("boolean"),
        "displayName": prop("string"),
        "displayNameHtml": prop("string"),
        "sslRequired": prop("string", "one of: all, external, none"),
        "loginTheme": prop("string"),
        "loginWithEmailAllowed": prop("boolean"),
        "registrationAllowed": prop("boolean"),
        "resetPasswordAllowed": prop("boolean"),
        "rememberMe": prop("boolean"),
        "accessTokenLifespan": prop("integer"),
        "ssoSessionIdleTimeout": prop("integer", "Shared-SSO idle timeout (seconds)."),
        "ssoSessionMaxLifespan": prop("integer", "Shared-SSO max session lifespan (seconds)."),
        "internationalizationEnabled": prop("boolean"),
        "defaultLocale": prop("string"),
        # --- MFA policy: OTP (TOTP/HOTP) ------------------------------------
        "otpPolicyType": prop("string", "totp or hotp."),
        "otpPolicyAlgorithm": prop("string", "e.g. HmacSHA1, HmacSHA256, HmacSHA512."),
        "otpPolicyDigits": prop("integer", "Number of digits in the OTP (6 or 8)."),
        "otpPolicyPeriod": prop("integer", "TOTP time step in seconds (e.g. 30)."),
        "otpPolicyLookAheadWindow": prop("integer"),
        "otpPolicyInitialCounter": prop("integer", "HOTP initial counter."),
        "otpPolicyCodeReusable": prop("boolean"),
        # --- MFA policy: WebAuthn (two-factor) ------------------------------
        "webAuthnPolicyRpEntityName": prop("string"),
        "webAuthnPolicyRpId": prop("string"),
        "webAuthnPolicySignatureAlgorithms": STRARR,
        "webAuthnPolicyAttestationConveyancePreference": prop("string", "none, indirect or direct."),
        "webAuthnPolicyAuthenticatorAttachment": prop("string", "platform or cross-platform."),
        "webAuthnPolicyRequireResidentKey": prop("string", "Yes/No/not specified."),
        "webAuthnPolicyUserVerificationRequirement": prop("string", "required, preferred or discouraged."),
        "webAuthnPolicyCreateTimeout": prop("integer"),
        "webAuthnPolicyAvoidSameAuthenticatorRegister": prop("boolean"),
        "webAuthnPolicyAcceptableAaguids": STRARR,
        # --- MFA policy: WebAuthn (passwordless) ----------------------------
        "webAuthnPolicyPasswordlessRpEntityName": prop("string"),
        "webAuthnPolicyPasswordlessRpId": prop("string"),
        "webAuthnPolicyPasswordlessSignatureAlgorithms": STRARR,
        "webAuthnPolicyPasswordlessAttestationConveyancePreference": prop("string"),
        "webAuthnPolicyPasswordlessAuthenticatorAttachment": prop("string"),
        "webAuthnPolicyPasswordlessRequireResidentKey": prop("string"),
        "webAuthnPolicyPasswordlessUserVerificationRequirement": prop("string"),
        "webAuthnPolicyPasswordlessCreateTimeout": prop("integer"),
        "webAuthnPolicyPasswordlessAvoidSameAuthenticatorRegister": prop("boolean"),
        "webAuthnPolicyPasswordlessAcceptableAaguids": STRARR,
        # --- Top-level flow bindings (point a realm at a managed flow) ------
        "browserFlow": prop("string", "Alias of the realm browser flow (e.g. a managed step-up flow)."),
        "directGrantFlow": prop("string", "Alias of the realm direct-grant flow."),
        # Free-form realm attributes. Also carries the realm-default
        # `acr.loa.map` (ACR -> Level-of-Authentication) when set realm-wide.
        "attributes": STRMAP,
    }),
    "client": ("ClientRepresentation", {
        "clientId": prop("string", "Public client identifier. Natural key (findby)."),
        "name": prop("string"),
        "description": prop("string"),
        "enabled": prop("boolean"),
        "protocol": prop("string", "openid-connect or saml"),
        "rootUrl": prop("string"),
        "baseUrl": prop("string"),
        "adminUrl": prop("string"),
        "redirectUris": STRARR,
        "webOrigins": STRARR,
        "publicClient": prop("boolean"),
        "bearerOnly": prop("boolean"),
        "standardFlowEnabled": prop("boolean", "Authorization Code flow."),
        "implicitFlowEnabled": prop("boolean"),
        "directAccessGrantsEnabled": prop("boolean"),
        "serviceAccountsEnabled": prop("boolean", "Needed for client_credentials (admin token client)."),
        "clientAuthenticatorType": prop("string", "e.g. client-secret"),
        "secret": prop("string", "Client secret (confidential clients)."),
        "frontchannelLogout": prop("boolean"),
        "fullScopeAllowed": prop("boolean"),
        "defaultClientScopes": STRARR,
        "optionalClientScopes": STRARR,
        "attributes": STRMAP,
        # Inline protocol mappers created/updated WITH the client — fully
        # declarative, no parent-UUID needed (unlike the standalone
        # ProtocolMapper resource). Ideal for mappers owned by a client you
        # also manage here (e.g. the `groups` mapper for SSO). Uses a $ref:
        # oasgen-provider drops inline array-of-object items.
        "protocolMappers": {"type": "array",
                            "items": {"$ref": "#/components/schemas/ClientProtocolMapperEntry"}},
    }),
    "protocolmapper": ("ProtocolMapperRepresentation", {
        "name": prop("string", "Mapper name. Natural key (findby)."),
        "protocol": prop("string", "openid-connect or saml"),
        "protocolMapper": prop("string", "e.g. oidc-group-membership-mapper, oidc-usermodel-attribute-mapper"),
        "consentRequired": prop("boolean"),
        "config": STRMAP,
    }),
    "clientscope": ("ClientScopeRepresentation", {
        "name": prop("string", "Client-scope name. Natural key (findby)."),
        "description": prop("string"),
        "protocol": prop("string"),
        "attributes": STRMAP,
    }),
    "group": ("GroupRepresentation", {
        "name": prop("string", "Group name. Natural key (findby)."),
        "path": prop("string"),
        "attributes": STRMAP,
        "realmRoles": STRARR,
        "clientRoles": {"type": "object", "additionalProperties": STRARR,
                        "description": "clientId -> [role] used for project/role mapping."},
    }),
    "identityprovider": ("IdentityProviderRepresentation", {
        "alias": prop("string", "IdP alias. Immutable natural key."),
        "displayName": prop("string"),
        "providerId": prop("string", "e.g. oidc, keycloak-oidc, saml, github"),
        "enabled": prop("boolean"),
        "trustEmail": prop("boolean"),
        "storeToken": prop("boolean"),
        "linkOnly": prop("boolean"),
        "hideOnLogin": prop("boolean"),
        "firstBrokerLoginFlowAlias": prop("string"),
        "config": STRMAP,
    }),
    "idpmapper": ("IdentityProviderMapperRepresentation", {
        "name": prop("string", "Mapper name. Natural key (findby)."),
        "identityProviderAlias": prop("string", "Parent IdP alias; must equal the {alias} path param."),
        "identityProviderMapper": prop("string", "e.g. hardcoded-group-idp-mapper, oidc-username-idp-mapper"),
        "config": STRMAP,
    }),
    # Top-level authentication flow *container* (alias + metadata). Individual
    # executions/subflows inside a flow are NOT managed here: the Keycloak
    # executions API is create-then-mutate with move-op ordering, which a single
    # declarative RestDefinition cannot express — see docs/ARCHITECTURE.md.
    "authenticationflow": ("AuthenticationFlowRepresentation", {
        "alias": prop("string", "Flow alias. Natural key (findby)."),
        "description": prop("string"),
        "providerId": prop("string", "Flow type; top-level flows use basic-flow."),
        "topLevel": prop("boolean", "True for a realm-bindable top-level flow."),
        "builtIn": prop("boolean"),
    }),
    # Required-action provider (e.g. CONFIGURE_TOTP, webauthn-register). Realms
    # ship the base actions built-in; this manages their enabled/default/priority
    # state (and can register new provider-based actions). Addressed by alias.
    "requiredaction": ("RequiredActionProviderRepresentation", {
        "alias": prop("string", "Required-action alias, e.g. CONFIGURE_TOTP. Natural key."),
        "name": prop("string", "Human-readable name."),
        "providerId": prop("string", "Provider id backing the action."),
        "enabled": prop("boolean"),
        "defaultAction": prop("boolean", "Applied to every new user when true."),
        "priority": prop("integer"),
        "config": STRMAP,
    }),
}

# Extra named component schemas referenced via $ref by a resource's main schema.
# (oasgen-provider supports $ref'd object items but drops inline array-of-object.)
EXTRA_SCHEMAS = {
    "client": {
        "ClientProtocolMapperEntry": {
            "type": "object",
            "properties": {
                "name": prop("string"),
                "protocol": prop("string", "openid-connect or saml"),
                "protocolMapper": prop("string", "e.g. oidc-group-membership-mapper"),
                "consentRequired": prop("boolean"),
                "config": STRMAP,
            },
        },
    },
}

# requiredfields per resource (the natural key)
REQUIRED = {"realm": ["realm"], "client": ["clientId"], "protocolmapper": ["name"],
            "clientscope": ["name"], "group": ["name"], "identityprovider": ["alias"],
            "idpmapper": ["name"], "authenticationflow": ["alias"], "requiredaction": ["alias"]}

# read-only fields surfaced in status (server-generated). None = the resource is
# addressed directly by its natural key and has no separate server id.
READONLY = {"realm": "id", "client": "id", "protocolmapper": "id",
            "clientscope": "id", "group": "id", "identityprovider": "internalId",
            "idpmapper": "id", "authenticationflow": "id", "requiredaction": None}

# (collection_path, item_path) — item uses {id} for uuid resources, natural key otherwise
PATHS = {
    "realm":            ("/admin/realms", "/admin/realms/{realm}"),
    "client":           ("/admin/realms/{realm}/clients", "/admin/realms/{realm}/clients/{id}"),
    "protocolmapper":   ("/admin/realms/{realm}/clients/{clientUuid}/protocol-mappers/models",
                         "/admin/realms/{realm}/clients/{clientUuid}/protocol-mappers/models/{id}"),
    "clientscope":      ("/admin/realms/{realm}/client-scopes", "/admin/realms/{realm}/client-scopes/{id}"),
    "group":            ("/admin/realms/{realm}/groups", "/admin/realms/{realm}/groups/{id}"),
    "identityprovider": ("/admin/realms/{realm}/identity-provider/instances",
                         "/admin/realms/{realm}/identity-provider/instances/{alias}"),
    "idpmapper":        ("/admin/realms/{realm}/identity-provider/instances/{alias}/mappers",
                         "/admin/realms/{realm}/identity-provider/instances/{alias}/mappers/{id}"),
    "authenticationflow": ("/admin/realms/{realm}/authentication/flows",
                           "/admin/realms/{realm}/authentication/flows/{id}"),
    "requiredaction":   ("/admin/realms/{realm}/authentication/required-actions",
                         "/admin/realms/{realm}/authentication/required-actions/{alias}"),
}

# Resources whose create endpoint is NOT the collection path. Keycloak registers
# a required action via a dedicated sub-path; the collection path only lists.
CREATE_PATHS = {
    "requiredaction": "/admin/realms/{realm}/authentication/register-required-action",
}

TITLES = {
    "realm": "Realm", "client": "Client", "protocolmapper": "Protocol Mapper",
    "clientscope": "Client Scope", "group": "Group", "identityprovider": "Identity Provider",
    "idpmapper": "Identity Provider Mapper", "authenticationflow": "Authentication Flow",
    "requiredaction": "Required Action",
}

def path_params(path):
    import re
    return re.findall(r"{([^}]+)}", path)

def make_oas(key):
    schema_name, props = SCHEMAS[key]
    coll, item = PATHS[key]
    ro = READONLY.get(key)
    # status schema: add read-only id field (only for resources that carry a
    # server-generated identifier distinct from their natural key)
    body_props = dict(props)
    full_props = dict(body_props)
    if ro:
        full_props[ro] = prop("string", "Server-generated identifier (read-only).", readOnly=True)

    components = {
        "securitySchemes": {"bearer": {"type": "http", "scheme": "bearer",
                                       "description": "Keycloak admin access token (OAuth2 Bearer)."}},
        "schemas": {schema_name: {"type": "object", "required": REQUIRED[key], "properties": full_props}},
    }
    components["schemas"].update(EXTRA_SCHEMAS.get(key, {}))

    def param(name):
        return {"name": name, "in": "path", "required": True, "schema": {"type": "string"}}

    ref = {"$ref": f"#/components/schemas/{schema_name}"}
    json_body = {"required": True, "content": {"application/json": {"schema": ref}}}
    json_resp = lambda code, desc: {code: {"description": desc,
                                           "content": {"application/json": {"schema": ref}}}}
    arr_resp = {"200": {"description": "OK", "content": {"application/json":
                {"schema": {"type": "array", "items": ref}}}}}

    # oasgen-provider only reads path parameters declared at the OPERATION level
    # (verified on a live cluster: path-item-level `parameters` are ignored, so
    # the param never lands in the generated CRD spec). Attach params per-op.
    create_path = CREATE_PATHS.get(key, coll)
    coll_params = [param(p) for p in path_params(coll)]
    item_params = [param(p) for p in path_params(item)]
    create_params = [param(p) for p in path_params(create_path)]

    post_op = {"operationId": f"create{key.title()}", "summary": f"Create {TITLES[key]}",
               "tags": [key], "parameters": create_params, "requestBody": json_body,
               "responses": {"201": {"description": "Created. Identifier returned via Location header."}}}
    list_op = {"operationId": f"list{key.title()}", "summary": f"List/find {TITLES[key]}",
               "tags": [key], "parameters": coll_params, "responses": arr_resp}

    paths = collections.OrderedDict()
    if create_path == coll:
        # collection: POST (create) + GET (findby/list) on the same path
        paths[coll] = {"post": post_op, "get": list_op}
    else:
        # create uses a dedicated endpoint (e.g. register-required-action);
        # the collection path only serves findby/list
        paths[create_path] = {"post": post_op}
        paths[coll] = {"get": list_op}
    # item: GET/PUT/DELETE
    paths[item] = {"get": {"operationId": f"get{key.title()}", "summary": f"Get {TITLES[key]}",
                           "tags": [key], "parameters": item_params, "responses": json_resp("200", "OK")},
                   "put": {"operationId": f"update{key.title()}", "summary": f"Update {TITLES[key]}",
                           "tags": [key], "parameters": item_params, "requestBody": json_body,
                           "responses": {"204": {"description": "Updated."}}},
                   "delete": {"operationId": f"delete{key.title()}", "summary": f"Delete {TITLES[key]}",
                              "tags": [key], "parameters": item_params,
                              "responses": {"204": {"description": "Deleted."}}}}

    doc = collections.OrderedDict()
    doc["openapi"] = "3.0.3"
    doc["info"] = {"title": f"Keycloak Admin API - {TITLES[key]} (KOG subset)",
                   "version": "v1",
                   "description": (f"Hand-curated OpenAPI 3.0 subset of the Keycloak Admin REST API "
                                   f"for the {TITLES[key]} resource, sufficient to manage it through "
                                   f"the Krateo Operator Generator (KOG). Declares the http/bearer "
                                   f"security scheme that the upstream Keycloak OAS omits.")}
    doc["servers"] = [{"url": "{{ .Values.keycloak.baseUrl }}",
                       "description": "Keycloak base URL (no trailing slash)."}]
    doc["security"] = [{"bearer": []}]
    doc["components"] = components
    doc["paths"] = paths
    return doc

# preserve insertion order in yaml; never emit anchors/aliases (expand repeats)
class NoAliasDumper(yaml.Dumper):
    def ignore_aliases(self, data): return True
NoAliasDumper.add_representer(collections.OrderedDict,
                     lambda d, data: d.represent_mapping("tag:yaml.org,2002:map", data.items()))

for key in SCHEMAS:
    out = f"../chart/assets/{key}.yaml"
    with open(out, "w") as f:
        yaml.dump(make_oas(key), f, Dumper=NoAliasDumper, sort_keys=False, default_flow_style=False, width=100)
    print("wrote", out)
