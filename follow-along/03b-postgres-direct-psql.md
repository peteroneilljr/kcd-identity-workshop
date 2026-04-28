# 03b — Postgres direct: interactive psql via OIDC-signed client cert

In [03](03-postgres-rls.md) you reached Postgres through `db-app`: HTTP request → JWT validated by Envoy → bridge service runs `SET LOCAL ROLE` → SQL fires under the assumed identity. That's the right pattern when an *application* needs row-level access. But what about a *human* who wants an interactive `psql` session?

This module is the same identity story in a second shape: a `pg-ca` service signs a short-lived **PostgreSQL client certificate** from the user's JWT, and Postgres validates that cert at connection time using its native `cert` auth method. The shell session you get is a normal `psql` — `\d`, multi-line queries, transactions, prepared statements — except `current_user` is your Keycloak identity, and Row-Level Security still filters rows the same way it does for `db-app`.

The pattern: **federated identity at the edge → short-lived protocol-native credential at the resource**. You already saw it for SSH in module 04 (which you'll get to next). Postgres is the third protocol. The bridge service is ~100 lines of Node.

[← back to index](README.md) · prev: [03-postgres-rls.md](03-postgres-rls.md) · next: [04-ssh-certs.md](04-ssh-certs.md)

## Prerequisite

[`00-setup.md`](00-setup.md) finished. The cluster has a `pg-ca` Deployment (separate from `ssh-ca`) and Postgres is running with TLS + cert auth enabled:

```bash
kubectl -n ams-demo get deploy/pg-ca
kubectl -n ams-demo get cm pg-ca-cert     # the CA cert (public — clients use as sslrootcert)
kubectl -n ams-demo get secret pg-ca-key  # CA private key (pg-ca service only)
```

You'll also need `psql` and `openssl` locally. macOS: `brew install libpq openssl`. Linux: `apt install postgresql-client openssl`.

Forward the Postgres port so your laptop can reach it:

```bash
kubectl -n ams-demo port-forward svc/postgres 5432:5432 &
```

## 1. Generate a local keypair + CSR

This is *your* PG client identity. The CA never sees your private key — only the CSR (which carries your public key + a *requested* subject).

```bash
mkdir -p ~/.pg-keycloak && cd ~/.pg-keycloak

openssl req -new -newkey rsa:2048 -nodes -sha256 \
  -keyout user.key -out user.csr \
  -subj "/CN=alice"

chmod 600 user.key   # psql refuses keys with looser perms
ls
```

Three files: `user.key` (private), `user.csr` (request), and shortly `user.crt` (signed cert).

The `/CN=alice` in the CSR is what *you're requesting*. The CA decides what to actually put in the signed cert — and as you'll see, it ignores your CN and substitutes the JWT identity.

## 2. Sign the CSR with your Keycloak token

```bash
TOKEN_ALICE=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -d "client_id=demo-client&grant_type=password&username=alice&password=password" | jq -r .access_token)

curl -sf -X POST -H "Authorization: Bearer $TOKEN_ALICE" \
  -H "Content-Type: text/plain" --data-binary @user.csr \
  http://localhost:8080/pg-ca/sign \
  > user.crt
```

Inspect what came back:

```bash
openssl x509 -in user.crt -noout -subject -issuer -dates
```

```
subject= /CN=alice
issuer= /CN=demo-pg-ca
notBefore=Apr 28 17:00:00 2026 GMT
notAfter=Apr 28 17:15:00 2026 GMT
```

Two things to notice:

1. **`subject = CN=alice`** — that's the JWT's `preferred_username`, not whatever you put in the CSR. (More on this below.)
2. **`notAfter = +15 minutes`** — short-lived. After expiry you re-sign with a fresh JWT.

## 3. Fetch the CA's public cert

Your `psql` client needs the CA cert to verify the Postgres *server* cert during the TLS handshake. The CA cert lives in a ConfigMap:

```bash
kubectl -n ams-demo get cm pg-ca-cert -o jsonpath='{.data.ca\.crt}' > ca.crt
```

## 4. Connect with psql

```bash
PGSSLCERT=~/.pg-keycloak/user.crt \
PGSSLKEY=~/.pg-keycloak/user.key \
PGSSLROOTCERT=~/.pg-keycloak/ca.crt \
  psql "host=localhost port=5432 dbname=demo user=alice sslmode=verify-ca"
```

You're in a real psql shell:

```sql
demo=> SELECT current_user, session_user, current_database();
 current_user | session_user | current_database
--------------+--------------+------------------
 alice        | alice        | demo
(1 row)

demo=> SELECT id, owner, title FROM documents ORDER BY id;
 id | owner  |        title
----+--------+---------------------
  1 | alice  | Alice notes
  2 | alice  | Alice TODO
  5 | public | Shared announcement
(3 rows)
```

Three things working together:

- **Postgres' `cert` auth** validated the cert chain (`ca.crt` was the trust anchor) and enforced that the cert's CN equals the requested DB user (`user=alice`).
- **`session_user = alice`** — you connected directly as alice, no `SET ROLE`. There's no dbproxy in this path.
- **RLS** — same `documents_owner_or_public` policy from module 03. `current_user` is `alice` so you see alice's rows + public; bob's rows are invisible.

Try the things you can't do via the HTTP path:

```sql
\dt                                         -- list tables (PG metaquery)
SELECT count(*) FROM documents;             -- still RLS-filtered: 3
EXPLAIN (ANALYZE) SELECT * FROM documents;  -- see how PG evaluates the policy
\q
```

## 5. Switch to bob — same private key, fresh cert

The cert is the only thing that changes. Re-sign with bob's JWT:

```bash
TOKEN_BOB=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -d "client_id=demo-client&grant_type=password&username=bob&password=password" | jq -r .access_token)

curl -sf -X POST -H "Authorization: Bearer $TOKEN_BOB" \
  -H "Content-Type: text/plain" --data-binary @user.csr \
  http://localhost:8080/pg-ca/sign \
  > user.crt

PGSSLCERT=~/.pg-keycloak/user.crt PGSSLKEY=~/.pg-keycloak/user.key PGSSLROOTCERT=~/.pg-keycloak/ca.crt \
  psql "host=localhost port=5432 dbname=demo user=bob sslmode=verify-ca" \
  -c "SELECT current_user; SELECT id, owner FROM documents ORDER BY id;"
```

```
 current_user
--------------
 bob

 id | owner
----+--------
  3 | bob
  4 | bob
  5 | public
```

Same CSR, same private key, **different identity** — controlled entirely by which JWT signed the cert. The private key never moves.

## 6. The security properties to convince yourself of

### a. The CA ignores the requested CN

The CSR you sent in step 1 had `CN=alice`. What if you ask for a cert as alice but request `CN=bob`?

```bash
openssl req -new -newkey rsa:2048 -nodes -sha256 \
  -keyout sneaky.key -out sneaky.csr -subj "/CN=bob"

curl -sf -X POST -H "Authorization: Bearer $TOKEN_ALICE" \
  -H "Content-Type: text/plain" --data-binary @sneaky.csr \
  http://localhost:8080/pg-ca/sign \
  | openssl x509 -noout -subject
```

```
subject= /CN=alice
```

The CA reads the JWT's `preferred_username` and overwrites the CSR's CN. The CSR's subject is *requested*; the cert's subject is *granted by the CA*.

### b. alice's cert can't connect as bob

Cross-user impersonation, with a valid alice cert but `user=bob` in the connection string:

```bash
TOKEN_ALICE=$(curl -s -X POST "http://localhost:8180/realms/demo/protocol/openid-connect/token" \
  -d "client_id=demo-client&grant_type=password&username=alice&password=password" | jq -r .access_token)

curl -sf -X POST -H "Authorization: Bearer $TOKEN_ALICE" \
  -H "Content-Type: text/plain" --data-binary @user.csr \
  http://localhost:8080/pg-ca/sign > user.crt

PGSSLCERT=~/.pg-keycloak/user.crt PGSSLKEY=~/.pg-keycloak/user.key PGSSLROOTCERT=~/.pg-keycloak/ca.crt \
  psql "host=localhost port=5432 dbname=demo user=bob sslmode=verify-ca" -c "SELECT 1"
```

```
psql: error: ... FATAL:  certificate authentication failed for user "bob"
```

Postgres' `cert` auth method requires CN to equal the requested user. Same enforcement as `AuthorizedPrincipalsFile` in the SSH module, just in a different layer.

### c. No JWT, no signing

```bash
curl -i -X POST -H "Content-Type: text/plain" --data-binary @user.csr \
  http://localhost:8080/pg-ca/sign
```

```
HTTP/1.1 401 Unauthorized
... Jwt is missing
```

Envoy's `jwt_authn` filter blocks the request before it reaches `pg-ca`.

### d. No cert, no connection

```bash
psql "host=localhost port=5432 dbname=demo user=alice sslmode=disable" -c "SELECT 1"
```

```
psql: error: ... FATAL:  pg_hba.conf rejects connection for host ..., user "alice", database "demo", no encryption
```

`pg_hba.conf` requires `hostssl` for the demo database — plaintext or no-cert attempts get rejected before auth.

## How it works

Three configurations conspire. The interesting bits in each:

**`docker/pg-ca-app/server.js`** (~80 lines):
```js
const cert = forge.pki.createCertificate();
cert.publicKey = csr.publicKey;                           // user's pubkey from CSR
cert.setSubject([{ name: 'commonName', value: user }]);   // CN = JWT user, not CSR's CN
cert.setIssuer(caCert.subject.attributes);
cert.setExtensions([
  { name: 'basicConstraints', cA: false },
  { name: 'keyUsage',    digitalSignature: true, keyEncipherment: true },
  { name: 'extKeyUsage', clientAuth: true },              // PG requires clientAuth
]);
cert.sign(caKey, forge.md.sha256.create());
```

**`k8s/config-src/pg_hba.conf`**:
```
# Cert auth for any user connecting to the demo database over TLS. The
# `cert` method requires clientcert verification (against ssl_ca_file)
# AND the cert's CN to equal the requested DB user. So a cert with
# CN=alice can only connect as user=alice.
hostssl   demo        all           0.0.0.0/0       cert
```

**`k8s/41-postgres.yaml`**:
```yaml
args:
  - postgres
  - -c
  - ssl=on
  - -c
  - ssl_cert_file=/etc/postgres-tls/server.crt
  - -c
  - ssl_key_file=/etc/postgres-tls/server.key
  - -c
  - ssl_ca_file=/etc/postgres-ca/ca.crt   # trust anchor for client certs
  - -c
  - hba_file=/etc/postgres-hba/pg_hba.conf
```

The CA keypair is generated on `kubectl apply -f k8s/` by the bootstrap Job in `k8s/06-pg-ca-bootstrap.yaml` — same idempotent pattern as the SSH CA. Re-applies are no-ops once the Secret/ConfigMap exist.

## Why this matters — and how it relates to the rest of the workshop

You've now seen Postgres reached via **two** identity-aware paths:

| | Module 03 (`db-app` SET ROLE) | This module (`pg-ca` cert) |
|---|---|---|
| Use case | An *application* serving HTTP needs identity-scoped DB access | A *human* wants an interactive psql session |
| Where identity is enforced | Postgres `current_user`, set by db-app's `SET LOCAL ROLE` | Postgres `cert` auth, no SET ROLE — connects directly as alice |
| What a buggy bridge could do | At worst, `SET LOCAL ROLE` to wrong user → wrong rows visible to that request | Can't even mint a cert with a forged CN — JWT username is server-side substituted |
| Trust unit | dbproxy connection + GRANT membership | CA cert as the root of trust |
| Lifetime | Per-request | 15-min cert |

Both paths share `documents_owner_or_public` RLS as the **last line of enforcement**. RLS doesn't know or care which path got the connection there — it only sees `current_user`.

Three observations to carry forward:

1. **The same federation pattern shows up at every layer.** `ssh-ca` (module 04) and `pg-ca` (this one) are mechanically identical: a small bridge, a JWT validation, a short-lived signed credential, native protocol-level enforcement at the resource.
2. **Postgres' `cert` auth is the analog of sshd's `AuthorizedPrincipalsFile`.** Both are file-based, declarative, "this CN/principal can be this user" mappings — both refuse to authenticate when the cert/principal doesn't match the requested identity, regardless of how valid the signing chain is.
3. **You don't have to invent an OIDC plugin for every system.** Postgres has zero understanding of JWTs and never will. But it has rich native auth (cert, scram-sha-256, ldap, gss, peer, …). Your bridge converts JWT → whichever native credential the resource speaks. Same as Vault SSH, AWS RDS IAM, Boundary, Teleport DB Access.

---

→ Next: [**04-ssh-certs.md**](04-ssh-certs.md) — the same pattern again, this time bridging JWT into SSH cert auth. By now the shape will feel familiar.
