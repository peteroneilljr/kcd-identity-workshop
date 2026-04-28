# Follow-Along Guide

Step-by-step, copy-paste-ready. By the end you'll have logged in as `alice` and `bob`, hit four different backends with the same Keycloak identity, and seen each one enforce who-sees-what.

The four enforcement points exercised here:

| # | Backend     | What enforces identity                                   |
| - | ----------- | -------------------------------------------------------- |
| 1 | HTTP apps   | Envoy `jwt_authn` + `rbac` filter on `preferred_username` |
| 2 | Postgres    | `SET ROLE <jwt-username>` inside a tx + RLS on `current_user` |
| 3 | Grafana     | Native OIDC code flow against Keycloak; JMESPath role mapping |
| 4 | SSH         | 15-min cert signed with principal = JWT username         |

## Prerequisites

- A running Kubernetes cluster (Docker Desktop's k8s, kind, minikube, …)
- `kubectl`, `docker` (to build the local app images)
- `curl`, `jq`, `python3`, `ssh`, `ssh-keygen`, `nc` for the client-side flows

## Setup

### 1. Build the local app images

Docker Desktop's k8s shares the docker daemon's image cache automatically. On plain `kind`, follow each build with `kind load docker-image <tag>`.

```bash
docker build -t demo-public-app:k8s   ./public-app
docker build -t demo-alice-app:k8s    ./alice-app
docker build -t demo-bob-app:k8s      ./bob-app
docker build -t demo-db-app:k8s       ./db-app
docker build -t demo-ssh-ca-app:k8s   ./ssh-ca-app
docker build -t demo-sshd:k8s         ./sshd-app
```

### 2. Apply everything and wait for Ready

The SSH CA keypair is auto-generated on first apply by a one-shot bootstrap Job (`k8s/05-ssh-ca-bootstrap.yaml`); no manual `ssh-keygen` step is required. The Job creates `Secret/ssh-ca-key` and `ConfigMap/ssh-ca-pub`, and the `ssh-ca` and `sshd` Deployments mount them.

```bash
kubectl apply -f k8s/
kubectl -n ams-demo wait --for=condition=Available --timeout=240s deploy --all
kubectl -n ams-demo get pods
```

Expect 10 pods Running plus a completed bootstrap Job:

```bash
kubectl -n ams-demo get job ssh-ca-bootstrap
# NAME               STATUS     COMPLETIONS   DURATION   AGE
# ssh-ca-bootstrap   Complete   1/1           ...        ...
```

### 3. Open user-facing ports

```bash
kubectl -n ams-demo port-forward svc/keycloak 8180:8180 &
kubectl -n ams-demo port-forward svc/envoy    8080:8080 &
kubectl -n ams-demo port-forward svc/grafana  3300:3000 &
kubectl -n ams-demo port-forward svc/sshd     2222:22   &
```

Quick sanity check:

```bash
curl -s -o /dev/null -w "kc=%{http_code}\n" http://localhost:8180/realms/demo
curl -s -o /dev/null -w "envoy=%{http_code}\n" http://localhost:8080/health
curl -s -o /dev/null -w "graf=%{http_code}\n" http://localhost:3300/api/health
nc -z localhost 2222 && echo "sshd=open"
```

---

## Part 1 — HTTP (Envoy + JWT + RBAC)

### Anon: every authenticated route is locked

```bash
curl -i http://localhost:8080/public  # 401
curl -i http://localhost:8080/alice   # 401
curl -i http://localhost:8080/bob     # 401
curl -i http://localhost:8080/health  # 200 (the only public route)
```

Envoy's `jwt_authn` filter rejects anything missing or with an invalid bearer.

### Get a token and inspect it

```bash
TOKEN_ALICE=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -d "client_id=demo-client&grant_type=password&username=alice&password=password" | jq -r .access_token)

# Decode the payload
PAYLOAD=$(echo "$TOKEN_ALICE" | cut -d. -f2)
case $((${#PAYLOAD} % 4)) in 2) PAYLOAD="${PAYLOAD}==" ;; 3) PAYLOAD="${PAYLOAD}=" ;; esac
echo "$PAYLOAD" | base64 -d 2>/dev/null | jq '{username: .preferred_username, email, roles: .realm_access.roles, exp}'
```

Expect:

```json
{ "username": "alice", "email": "alice@demo.local", "roles": ["user"], "exp": 1234567890 }
```

### alice can hit `/public` and `/alice`, but not `/bob`

```bash
curl -H "Authorization: Bearer $TOKEN_ALICE" http://localhost:8080/public | jq '{authenticated_user, jwt_claims}'
curl -H "Authorization: Bearer $TOKEN_ALICE" http://localhost:8080/alice  | jq '{authenticated_user, jwt_claims}'
curl -i -H "Authorization: Bearer $TOKEN_ALICE" http://localhost:8080/bob   # 403
```

The 403 is the moment that matters: Alice has a valid token, but the RBAC policy `allow-bob-only` requires `preferred_username == "bob"`.

### bob is the mirror image — and admin role doesn't override it

```bash
TOKEN_BOB=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -d "client_id=demo-client&grant_type=password&username=bob&password=password" | jq -r .access_token)

curl    -H "Authorization: Bearer $TOKEN_BOB" http://localhost:8080/public  # 200
curl    -H "Authorization: Bearer $TOKEN_BOB" http://localhost:8080/bob     # 200
curl -i -H "Authorization: Bearer $TOKEN_BOB" http://localhost:8080/alice   # 403
```

Bob has the `admin` realm role. RBAC keys on identity, not roles, so admin doesn't help here.

---

## Part 2 — Postgres (SET ROLE + RLS)

`/db` is reachable by any authenticated user; the database itself filters per-row using `current_user` after `db-app` runs `SET LOCAL ROLE "<jwt-username>"` inside a transaction.

```bash
curl -s -H "Authorization: Bearer $TOKEN_ALICE" http://localhost:8080/db | jq '.visible_documents'
```

Expect alice's two rows + the `public` row, never bob's:

```json
[
  { "id": 1, "owner": "alice",  "title": "Alice notes",          "body": "..." },
  { "id": 2, "owner": "alice",  "title": "Alice TODO",           "body": "..." },
  { "id": 5, "owner": "public", "title": "Shared announcement",  "body": "..." }
]
```

```bash
curl -s -H "Authorization: Bearer $TOKEN_BOB" http://localhost:8080/db | jq '.visible_documents'
```

Mirror image — bob sees only `{bob, public}`.

The trust boundary is the database, not `db-app`. Even if `db-app` had a bug, the RLS policy `USING (owner = current_user OR owner = 'public')` would still scope rows to the current role.

### Optional: interactive psql against the same DB

```bash
kubectl -n ams-demo port-forward svc/postgres 5432:5432 &
PGPASSWORD=dbproxy psql -h localhost -U dbproxy demo
demo=> SET ROLE alice;
demo=> SELECT * FROM documents;             -- alice's view
demo=> RESET ROLE; SET ROLE bob;
demo=> SELECT * FROM documents;             -- bob's view
demo=> RESET ROLE;
demo=> SELECT * FROM documents;             -- dbproxy with no role: blank, RLS denies all
```

`dbproxy` is `NOINHERIT`, so it has no privileges on its own — only what it inherits via `SET ROLE`.

---

## Part 3 — Grafana (OIDC code flow)

Grafana speaks OIDC natively, so it goes straight to Keycloak — Envoy is **not** in this path.

### Browser flow

Open <http://localhost:3300/login> → click **Sign in with Keycloak** → log in as `alice/password` or `bob/password`.

First login auto-provisions the user in Grafana. You'll land in the Grafana UI as that user.

### What role you'll get

Grafana maps Keycloak's `realm_access.roles` to a Grafana org role with this JMESPath:

```ini
role_attribute_path = contains(realm_access.roles[*], 'admin') && 'Admin' || 'Viewer'
```

So:
- `alice` (realm roles `[user]`) → Grafana **Viewer**
- `bob`   (realm roles `[user, admin]`) → Grafana **Admin**

### Verify with the API after logging in

In the same browser session that just logged in:

```
http://localhost:3300/api/user/orgs
```

You'll see something like `[{"orgId":1,"name":"Main Org.","role":"Admin"}]` for bob, `Viewer` for alice. `isExternallySynced=true` on `/api/user` confirms Grafana sourced the user from Keycloak rather than its local DB.

---

## Part 4 — SSH (CA-signed short-lived certs)

The pattern: HTTP `POST /ssh-ca/sign` your SSH public key with a Keycloak token. Get back a 15-minute SSH cert whose `Principal` is your JWT username. sshd trusts the CA's pubkey but only honors certs whose principal matches the per-user `auth_principals/<user>` file.

### One-time: a local SSH keypair

```bash
ssh-keygen -t ed25519 -f ~/.ssh/keycloak_id -N "" -C "$(whoami)@laptop"
```

### Sign a cert for alice

```bash
TOKEN_ALICE=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -d "client_id=demo-client&grant_type=password&username=alice&password=password" | jq -r .access_token)

curl -sf -X POST -H "Authorization: Bearer $TOKEN_ALICE" \
  -H "Content-Type: text/plain" --data-binary @"$HOME/.ssh/keycloak_id.pub" \
  http://localhost:8080/ssh-ca/sign > "$HOME/.ssh/keycloak_id-cert.pub"

ssh-keygen -L -f ~/.ssh/keycloak_id-cert.pub | head -10
```

Expect to see `Principals: alice` and a `Valid:` window of about 15 minutes.

### ssh in as alice (the cert beside the key is picked up automatically)

```bash
ssh -i ~/.ssh/keycloak_id -p 2222 alice@localhost
# inside the session:
whoami        # alice
hostname      # sshd-...
cat /etc/os-release | head -2
exit
```

### alice's cert is rejected as bob

```bash
ssh -i ~/.ssh/keycloak_id -p 2222 bob@localhost whoami
# Permission denied (publickey).
```

`auth_principals/bob` only contains `bob`. The cert's principal is `alice`, so sshd refuses even though the CA-signed cert is technically valid.

### Now sign a cert for bob and ssh in as bob

```bash
TOKEN_BOB=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -d "client_id=demo-client&grant_type=password&username=bob&password=password" | jq -r .access_token)

curl -sf -X POST -H "Authorization: Bearer $TOKEN_BOB" \
  -H "Content-Type: text/plain" --data-binary @"$HOME/.ssh/keycloak_id.pub" \
  http://localhost:8080/ssh-ca/sign > "$HOME/.ssh/keycloak_id-cert.pub"

ssh -i ~/.ssh/keycloak_id -p 2222 bob@localhost whoami   # bob
```

You overwrite the `*-cert.pub`; the ssh client picks up the new principal automatically. Same private key, different identity, controlled by which Keycloak token you used to sign.

---

## Experiments

### Token expiration

```bash
sleep 305
curl -i -H "Authorization: Bearer $TOKEN_ALICE" http://localhost:8080/alice    # 401, exp passed
```

### Tampered token

```bash
FAKE="${TOKEN_ALICE:0:50}HACKED${TOKEN_ALICE:56}"
curl -i -H "Authorization: Bearer $FAKE" http://localhost:8080/alice           # 401, signature invalid
```

### Cross-cutting access matrix (one-liner)

```bash
for U in alice bob; do
  T=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
       -d "client_id=demo-client&grant_type=password&username=$U&password=password" | jq -r .access_token)
  for P in /public /alice /bob /db; do
    printf "%-5s %-8s -> %s\n" "$U" "$P" "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $T" http://localhost:8080$P)"
  done
done
```

Expected:

```
alice /public   -> 200
alice /alice    -> 200
alice /bob      -> 403
alice /db       -> 200
bob   /public   -> 200
bob   /alice    -> 403
bob   /bob      -> 200
bob   /db       -> 200
```

### Run the full assertion suite

```bash
./tests/test-demo.sh
```

25 assertions across all four suites. Should print `ALL 25 ASSERTIONS PASSED`.

---

## Cleanup

```bash
# Stop port-forwards
pkill -f "kubectl port-forward"

# Tear down everything
kubectl delete namespace ams-demo
```

---

## Troubleshooting

**`namespace ams-demo not found`** — you skipped step 3. Run `kubectl apply -f k8s/`.

**`401 Jwt is missing`** — your token expired (5 min lifetime by default) or you forgot the Authorization header. Re-fetch the token.

**`403 access denied`** — that's the demo working. alice can't read `/bob`; bob can't read `/alice`.

**`no jwt identity` from `/db` or `/ssh-ca/sign`** — Envoy didn't forward `x-jwt-payload`. Check `kubectl -n ams-demo logs deploy/envoy | grep -i jwt`.

**Grafana SSO button does nothing** — confirm `kubectl -n ams-demo get pod -l app=grafana` shows Ready. The container takes ~10s to fully boot OIDC after the readiness probe passes.

**SSH `Permission denied (publickey)` for the same-user case** — your cert may have expired. Re-sign with a fresh token. `ssh-keygen -L -f ~/.ssh/keycloak_id-cert.pub` shows the validity window.

**Pod stuck in `ImagePullBackOff` for postgres or ubuntu** — transient registry hiccup. `docker pull postgres:16-alpine ubuntu:22.04` to warm the local cache and the kubelet will retry.

---

**End of guide.** You've now seen one Keycloak identity reach four heterogeneous backends — HTTP, SQL, dashboard UI, shell — with a different enforcement mechanism at each layer.
