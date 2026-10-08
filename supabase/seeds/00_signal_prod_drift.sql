-- LOCAL ONLY. Seeds never run against a linked project.
--
-- What production has but its migrations don't was recorded on 2026-10-08 in
-- 20261008100000_record_production_drift.sql. One difference is the platform,
-- not the schema: pg_graphql ships with the local image but isn't installed
-- in production.
drop extension if exists pg_graphql;
