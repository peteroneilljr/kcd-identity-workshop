-- Audit logging extension. shared_preload_libraries=pgaudit is set on the
-- server (k8s/41-postgres.yaml -c args), so the lib is already loaded; this
-- just attaches the hooks. After this, every read/write/role/ddl statement
-- gets logged with classification (AUDIT: SESSION,1,1,READ,SELECT,...).
CREATE EXTENSION IF NOT EXISTS pgaudit;

-- Roles for each Keycloak identity. NOLOGIN: they're assumed via SET ROLE
-- by the dbproxy connection, not connected to directly.
CREATE ROLE alice NOLOGIN;
CREATE ROLE bob   NOLOGIN;

-- Login role used by db-app to connect. Holds membership in alice/bob so
-- it can SET ROLE to either, but inherits no privileges itself (NOINHERIT).
CREATE ROLE dbproxy WITH LOGIN PASSWORD 'dbproxy' NOINHERIT;
GRANT alice TO dbproxy;
GRANT bob   TO dbproxy;

-- Schema/table the demo queries.
CREATE TABLE documents (
  id    SERIAL PRIMARY KEY,
  owner TEXT NOT NULL,
  title TEXT NOT NULL,
  body  TEXT NOT NULL
);

INSERT INTO documents (owner, title, body) VALUES
  ('alice',  'Alice notes',           'Private notes belonging to alice'),
  ('alice',  'Alice TODO',            'Buy milk; finish demo'),
  ('bob',    'Bob notes',             'Private notes belonging to bob'),
  ('bob',    'Bob deploy plan',       'Roll out v2 next sprint'),
  ('public', 'Shared announcement',   'Visible to anyone with a DB role');

-- Both roles need SELECT on the table for RLS to even consider the rows.
GRANT SELECT ON documents TO alice, bob;
GRANT USAGE,SELECT ON SEQUENCE documents_id_seq TO alice, bob;

-- RLS: users see rows they own, plus rows marked 'public'.
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE documents FORCE ROW LEVEL SECURITY;

CREATE POLICY documents_owner_or_public ON documents
  FOR SELECT
  USING (owner = current_user OR owner = 'public');
