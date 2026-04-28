# Postgres 16 + pgaudit — used by the audit-trail workshop modules to
# emit structured AUDIT log lines (READ/WRITE/ROLE/DDL classifications)
# alongside the standard log_statement=all output. Promtail ships both
# to Loki, where they're queryable per-user via the assumed DB role.
#
# Uses the Debian-based postgres image rather than -alpine, because the
# upstream PostgreSQL APT repo (already configured in the bookworm
# variant) packages postgresql-16-pgaudit — not so for the Alpine flavor.
FROM postgres:16-bookworm

RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-16-pgaudit \
 && rm -rf /var/lib/apt/lists/*
