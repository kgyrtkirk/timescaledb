-- This file and its contents are licensed under the Timescale License.
-- Please see the included NOTICE for copyright information and
-- LICENSE-TIMESCALE for a copy of the license.

\ir include/rand_generator.sql
\c :TEST_DBNAME :ROLE_SUPERUSER

SET client_min_messages = ERROR;
DROP TABLESPACE IF EXISTS tablespace1;
DROP TABLESPACE IF EXISTS tablespace2;
SET client_min_messages = NOTICE;
--test hypertable with tables space
CREATE TABLESPACE tablespace1 OWNER :ROLE_DEFAULT_PERM_USER LOCATION :TEST_TABLESPACE1_PATH;
CREATE TABLESPACE tablespace2 OWNER :ROLE_DEFAULT_PERM_USER LOCATION :TEST_TABLESPACE2_PATH;

\c :TEST_DBNAME :ROLE_DEFAULT_PERM_USER

CREATE TABLE test1 ("Time" timestamptz, i integer, b bigint, t text);
SELECT table_name from create_hypertable('test1', 'Time', chunk_time_interval=> INTERVAL '1 day');

INSERT INTO test1 SELECT t,  gen_rand_minstd(), gen_rand_minstd(), gen_rand_minstd()::text FROM generate_series('2018-03-02 1:00'::TIMESTAMPTZ, '2018-03-28 1:00', '1 hour') t;

ALTER TABLE test1 set (timescaledb.compress, timescaledb.compress_segmentby = 'b', timescaledb.compress_orderby = '"Time" DESC');

SELECT COUNT(*) AS count_compressed
FROM
(
SELECT compress_chunk(chunk.schema_name|| '.' || chunk.table_name)
FROM _timescaledb_catalog.chunk chunk
INNER JOIN _timescaledb_catalog.hypertable hypertable ON (chunk.hypertable_id = hypertable.id)
WHERE hypertable.table_name like 'test1' and chunk.compressed_chunk_id IS NULL ORDER BY chunk.id
)
AS sub;


--make sure allowed ddl still work
ALTER TABLE test1 CLUSTER ON "test1_Time_idx";
ALTER TABLE test1 SET WITHOUT CLUSTER;
CREATE INDEX new_index ON test1(b);
DROP INDEX new_index;
ALTER TABLE test1 SET (fillfactor=100);
ALTER TABLE test1 RESET (fillfactor);
ALTER TABLE test1 ALTER COLUMN b SET STATISTICS 10;

--test adding boolean columns with default and not null
CREATE TABLE records (time timestamp NOT NULL);
SELECT create_hypertable('records', 'time');
ALTER TABLE records SET (timescaledb.compress = true);
ALTER TABLE records ADD COLUMN col1 boolean DEFAULT false NOT NULL;
-- NULL constraints are useless and it is safe allow adding this
-- column with NULL constraint to a compressed hypertable (Issue #5151)
ALTER TABLE records ADD COLUMN col2 BOOLEAN NULL;
DROP table records CASCADE;

-- TABLESPACES
-- For tablepaces with compressed chunks the semantics are the following:
--  - compressed chunks get put into the same tablespace as the
--    uncompressed chunk on compression.
-- - set tablespace on uncompressed hypertable cascades to compressed hypertable+chunks
-- - set tablespace on all chunks is blocked (same as w/o compression)
-- - move chunks on a uncompressed chunk errors
-- - move chunks on compressed chunk works

--In the future we will:
-- - add tablespace option to compress_chunk function and policy (this will override the setting
--   of the uncompressed chunk). This will allow changing tablespaces upon compression
-- - Note: The current plan is to never listen to the setting on compressed hypertable. In fact,
--   we will block setting tablespace on  compressed hypertables


SELECT count(*) as "COUNT_CHUNKS_UNCOMPRESSED"
FROM _timescaledb_catalog.chunk chunk
INNER JOIN _timescaledb_catalog.hypertable hypertable ON (chunk.hypertable_id = hypertable.id)
WHERE hypertable.table_name like 'test1' \gset

SELECT count(*) as "COUNT_CHUNKS_COMPRESSED"
FROM _timescaledb_catalog.chunk chunk
INNER JOIN _timescaledb_catalog.hypertable comp_hyper ON (chunk.hypertable_id = comp_hyper.id)
INNER JOIN _timescaledb_catalog.hypertable uncomp_hyper ON (comp_hyper.id = uncomp_hyper.compressed_hypertable_id)
WHERE uncomp_hyper.table_name like 'test1' \gset

ALTER TABLE test1 SET TABLESPACE tablespace1;

--all chunks + both the compressed and uncompressed hypertable moved to new tablespace
SELECT count(*) = (:COUNT_CHUNKS_UNCOMPRESSED +:COUNT_CHUNKS_COMPRESSED + 2)
FROM pg_tables WHERE tablespace = 'tablespace1';

ALTER TABLE test1 SET TABLESPACE tablespace2;
SELECT count(*) = (:COUNT_CHUNKS_UNCOMPRESSED +:COUNT_CHUNKS_COMPRESSED + 2)
FROM pg_tables WHERE tablespace = 'tablespace2';

SELECT
    comp_chunk.schema_name|| '.' || comp_chunk.table_name as "COMPRESSED_CHUNK_NAME",
    uncomp_chunk.schema_name|| '.' || uncomp_chunk.table_name as "UNCOMPRESSED_CHUNK_NAME"
FROM _timescaledb_catalog.chunk comp_chunk
INNER JOIN _timescaledb_catalog.hypertable comp_hyper ON (comp_chunk.hypertable_id = comp_hyper.id)
INNER JOIN _timescaledb_catalog.hypertable uncomp_hyper ON (comp_hyper.id = uncomp_hyper.compressed_hypertable_id)
INNER JOIN _timescaledb_catalog.chunk uncomp_chunk ON (uncomp_chunk.compressed_chunk_id = comp_chunk.id)
WHERE uncomp_hyper.table_name like 'test1' ORDER BY comp_chunk.id LIMIT 1\gset

-- ensure compression chunk cannot be moved directly
SELECT tablename
FROM pg_tables WHERE tablespace = 'tablespace1';

\set ON_ERROR_STOP 0
ALTER TABLE :COMPRESSED_CHUNK_NAME SET TABLESPACE tablespace1;
\set ON_ERROR_STOP 1
SELECT tablename
FROM pg_tables WHERE tablespace = 'tablespace1';

-- ensure that both compressed and uncompressed chunks moved
ALTER TABLE :UNCOMPRESSED_CHUNK_NAME SET TABLESPACE tablespace1;
SELECT tablename
FROM pg_tables WHERE tablespace = 'tablespace1';

ALTER TABLE test1 SET TABLESPACE tablespace2;
SELECT tablename
FROM pg_tables WHERE tablespace = 'tablespace1';

\set ON_ERROR_STOP 0
SELECT move_chunk(chunk=>:'COMPRESSED_CHUNK_NAME', destination_tablespace=>'tablespace1', index_destination_tablespace=>'tablespace1',  reorder_index=>'_timescaledb_internal."compress_hyper_2_28_chunk__compressed_hypertable_2_b__ts_meta_s"');
\set ON_ERROR_STOP 1

-- ensure that both compressed and uncompressed chunks moved
SELECT move_chunk(chunk=>:'UNCOMPRESSED_CHUNK_NAME', destination_tablespace=>'tablespace1', index_destination_tablespace=>'tablespace1',  reorder_index=>'_timescaledb_internal."_hyper_1_1_chunk_test1_Time_idx"');
SELECT tablename
FROM pg_tables WHERE tablespace = 'tablespace1';

-- the compressed chunk is in here now
SELECT count(*)
FROM pg_tables WHERE tablespace = 'tablespace1';

SELECT decompress_chunk(:'UNCOMPRESSED_CHUNK_NAME');

--the compresse chunk was dropped by decompression
SELECT count(*)
FROM pg_tables WHERE tablespace = 'tablespace1';

SELECT move_chunk(chunk=>:'UNCOMPRESSED_CHUNK_NAME', destination_tablespace=>'tablespace1', index_destination_tablespace=>'tablespace1',  reorder_index=>'_timescaledb_internal."_hyper_1_1_chunk_test1_Time_idx"');

--the uncompressed chunks has now been moved
SELECT count(*)
FROM pg_tables WHERE tablespace = 'tablespace1';

SELECT compress_chunk(:'UNCOMPRESSED_CHUNK_NAME');

--the compressed chunk is now in the same tablespace as the uncompressed one
SELECT count(*)
FROM pg_tables WHERE tablespace = 'tablespace1';

--
-- DROP CHUNKS
--
SELECT count(*) as count_chunks_uncompressed
FROM _timescaledb_catalog.chunk chunk
INNER JOIN _timescaledb_catalog.hypertable hypertable ON (chunk.hypertable_id = hypertable.id)
WHERE hypertable.table_name like 'test1';

SELECT count(*) as count_chunks_compressed
FROM _timescaledb_catalog.chunk chunk
INNER JOIN _timescaledb_catalog.hypertable comp_hyper ON (chunk.hypertable_id = comp_hyper.id)
INNER JOIN _timescaledb_catalog.hypertable uncomp_hyper ON (comp_hyper.id = uncomp_hyper.compressed_hypertable_id)
WHERE uncomp_hyper.table_name like 'test1';


SELECT chunk.schema_name|| '.' || chunk.table_name as "UNCOMPRESSED_CHUNK_NAME"
FROM _timescaledb_catalog.chunk chunk
INNER JOIN _timescaledb_catalog.hypertable hypertable ON (chunk.hypertable_id = hypertable.id)
WHERE hypertable.table_name like 'test1' ORDER BY chunk.id LIMIT 1 \gset

DROP TABLE :UNCOMPRESSED_CHUNK_NAME;

--should decrease #chunks both compressed and decompressed
SELECT count(*) as count_chunks_uncompressed
FROM _timescaledb_catalog.chunk chunk
INNER JOIN _timescaledb_catalog.hypertable hypertable ON (chunk.hypertable_id = hypertable.id)
WHERE hypertable.table_name like 'test1';

--make sure there are no orphaned  _timescaledb_catalog.compression_chunk_size entries (should be 0)
SELECT count(*) as orphaned_compression_chunk_size
FROM _timescaledb_catalog.compression_chunk_size size
LEFT JOIN _timescaledb_catalog.chunk chunk ON (chunk.id = size.chunk_id)
WHERE chunk.id IS NULL;

SELECT count(*) as count_chunks_compressed
FROM _timescaledb_catalog.chunk chunk
INNER JOIN _timescaledb_catalog.hypertable comp_hyper ON (chunk.hypertable_id = comp_hyper.id)
INNER JOIN _timescaledb_catalog.hypertable uncomp_hyper ON (comp_hyper.id = uncomp_hyper.compressed_hypertable_id)
WHERE uncomp_hyper.table_name like 'test1';

SELECT drop_chunks('test1', older_than => '2018-03-10'::TIMESTAMPTZ);

--should decrease #chunks both compressed and decompressed
SELECT count(*) as count_chunks_uncompressed
FROM _timescaledb_catalog.chunk chunk
INNER JOIN _timescaledb_catalog.hypertable hypertable ON (chunk.hypertable_id = hypertable.id)
WHERE hypertable.table_name like 'test1';

SELECT count(*) as count_chunks_compressed
FROM _timescaledb_catalog.chunk chunk
INNER JOIN _timescaledb_catalog.hypertable comp_hyper ON (chunk.hypertable_id = comp_hyper.id)
INNER JOIN _timescaledb_catalog.hypertable uncomp_hyper ON (comp_hyper.id = uncomp_hyper.compressed_hypertable_id)
WHERE uncomp_hyper.table_name like 'test1';

SELECT chunk.schema_name|| '.' || chunk.table_name as "UNCOMPRESSED_CHUNK_NAME"
FROM _timescaledb_catalog.chunk chunk
INNER JOIN _timescaledb_catalog.hypertable hypertable ON (chunk.hypertable_id = hypertable.id)
WHERE hypertable.table_name like 'test1' ORDER BY chunk.id LIMIT 1 \gset

SELECT chunk.schema_name|| '.' || chunk.table_name as "COMPRESSED_CHUNK_NAME"
FROM _timescaledb_catalog.chunk chunk
INNER JOIN _timescaledb_catalog.hypertable comp_hyper ON (chunk.hypertable_id = comp_hyper.id)
INNER JOIN _timescaledb_catalog.hypertable uncomp_hyper ON (comp_hyper.id = uncomp_hyper.compressed_hypertable_id)
WHERE uncomp_hyper.table_name like 'test1' ORDER BY chunk.id LIMIT 1
\gset

\set ON_ERROR_STOP 0
DROP TABLE :COMPRESSED_CHUNK_NAME;
\set ON_ERROR_STOP 1

SELECT
    chunk.schema_name|| '.' || chunk.table_name as "UNCOMPRESSED_CHUNK_NAME",
    comp_chunk.schema_name|| '.' || comp_chunk.table_name as "COMPRESSED_CHUNK_NAME"
FROM _timescaledb_catalog.chunk chunk
INNER JOIN _timescaledb_catalog.chunk comp_chunk ON (chunk.compressed_chunk_id = comp_chunk.id)
INNER JOIN _timescaledb_catalog.hypertable hypertable ON (chunk.hypertable_id = hypertable.id)
WHERE hypertable.table_name like 'test1' ORDER BY chunk.id LIMIT 1 \gset

--create a dependent object on the compressed chunk to test cascade behaviour
CREATE VIEW dependent_1 AS SELECT * FROM :COMPRESSED_CHUNK_NAME;

\set ON_ERROR_STOP 0
--errors due to dependent objects
DROP TABLE :UNCOMPRESSED_CHUNK_NAME;
\set ON_ERROR_STOP 1

DROP TABLE :UNCOMPRESSED_CHUNK_NAME CASCADE;

--should decrease #chunks both compressed and decompressed
SELECT count(*) as count_chunks_uncompressed
FROM _timescaledb_catalog.chunk chunk
INNER JOIN _timescaledb_catalog.hypertable hypertable ON (chunk.hypertable_id = hypertable.id)
WHERE hypertable.table_name like 'test1';

SELECT count(*) as count_chunks_compressed
FROM _timescaledb_catalog.chunk chunk
INNER JOIN _timescaledb_catalog.hypertable comp_hyper ON (chunk.hypertable_id = comp_hyper.id)
INNER JOIN _timescaledb_catalog.hypertable uncomp_hyper ON (comp_hyper.id = uncomp_hyper.compressed_hypertable_id)
WHERE uncomp_hyper.table_name like 'test1';

SELECT
    chunk.schema_name|| '.' || chunk.table_name as "UNCOMPRESSED_CHUNK_NAME",
    comp_chunk.schema_name|| '.' || comp_chunk.table_name as "COMPRESSED_CHUNK_NAME"
FROM _timescaledb_catalog.chunk chunk
INNER JOIN _timescaledb_catalog.chunk comp_chunk ON (chunk.compressed_chunk_id = comp_chunk.id)
INNER JOIN _timescaledb_catalog.hypertable hypertable ON (chunk.hypertable_id = hypertable.id)
WHERE hypertable.table_name like 'test1' ORDER BY chunk.id LIMIT 1 \gset

CREATE VIEW dependent_1 AS SELECT * FROM :COMPRESSED_CHUNK_NAME;

\set ON_ERROR_STOP 0
\set VERBOSITY default
--errors due to dependent objects
SELECT drop_chunks('test1', older_than => '2018-03-28'::TIMESTAMPTZ);
\set VERBOSITY terse
\set ON_ERROR_STOP 1

DROP VIEW dependent_1;
SELECT drop_chunks('test1', older_than => '2018-03-28'::TIMESTAMPTZ);

--should decrease #chunks both compressed and decompressed
SELECT count(*) as count_chunks_uncompressed
FROM _timescaledb_catalog.chunk chunk
INNER JOIN _timescaledb_catalog.hypertable hypertable ON (chunk.hypertable_id = hypertable.id)
WHERE hypertable.table_name like 'test1';

SELECT count(*) as count_chunks_compressed
FROM _timescaledb_catalog.chunk chunk
INNER JOIN _timescaledb_catalog.hypertable comp_hyper ON (chunk.hypertable_id = comp_hyper.id)
INNER JOIN _timescaledb_catalog.hypertable uncomp_hyper ON (comp_hyper.id = uncomp_hyper.compressed_hypertable_id)
WHERE uncomp_hyper.table_name like 'test1';

--make sure there are no orphaned  _timescaledb_catalog.compression_chunk_size entries (should be 0)
SELECT count(*) as orphaned_compression_chunk_size
FROM _timescaledb_catalog.compression_chunk_size size
LEFT JOIN _timescaledb_catalog.chunk chunk ON (chunk.id = size.chunk_id)
WHERE chunk.id IS NULL;

--
-- DROP HYPERTABLE
--

SELECT comp_hyper.schema_name|| '.' || comp_hyper.table_name as "COMPRESSED_HYPER_NAME"
FROM _timescaledb_catalog.hypertable comp_hyper
INNER JOIN _timescaledb_catalog.hypertable uncomp_hyper ON (comp_hyper.id = uncomp_hyper.compressed_hypertable_id)
WHERE uncomp_hyper.table_name like 'test1' ORDER BY comp_hyper.id LIMIT 1 \gset

\set ON_ERROR_STOP 0
DROP TABLE :COMPRESSED_HYPER_NAME;
\set ON_ERROR_STOP 1

BEGIN;
SELECT hypertable.schema_name|| '.' || hypertable.table_name as "UNCOMPRESSED_HYPER_NAME"
FROM _timescaledb_catalog.hypertable hypertable
WHERE hypertable.table_name like 'test1' ORDER BY hypertable.id LIMIT 1 \gset

--before the drop there are 2 hypertables: the compressed and uncompressed ones
SELECT count(*) FROM _timescaledb_catalog.hypertable hypertable;
--add policy to make sure it's dropped later
select add_compression_policy(:'UNCOMPRESSED_HYPER_NAME', interval '1 day');
SELECT count(*) FROM _timescaledb_config.bgw_job WHERE id >= 1000;

DROP TABLE :UNCOMPRESSED_HYPER_NAME;

--verify that there are no more hypertable remaining
SELECT count(*) FROM _timescaledb_catalog.hypertable hypertable;
SELECT count(*) FROM _timescaledb_catalog.hypertable_compression;

--verify that the policy is gone
SELECT count(*) FROM _timescaledb_config.bgw_job WHERE id >= 1000;

ROLLBACK;

--create a dependent object on the compressed hypertable to test cascade behaviour

CREATE VIEW dependent_1 AS SELECT * FROM :COMPRESSED_HYPER_NAME;
\set ON_ERROR_STOP 0
DROP TABLE :UNCOMPRESSED_HYPER_NAME;
\set ON_ERROR_STOP 1

BEGIN;
DROP TABLE :UNCOMPRESSED_HYPER_NAME CASCADE;
SELECT count(*) FROM _timescaledb_catalog.hypertable hypertable;
ROLLBACK;
DROP VIEW dependent_1;


--create a cont agg view on the ht as well then the drop should nuke everything
CREATE MATERIALIZED VIEW test1_cont_view
WITH (timescaledb.continuous,
      timescaledb.materialized_only=true)
AS SELECT time_bucket('1 hour', "Time"), SUM(i)
   FROM test1
   GROUP BY 1 WITH NO DATA;
SELECT add_continuous_aggregate_policy('test1_cont_view', NULL, '1 hour'::interval, '1 day'::interval);
CALL refresh_continuous_aggregate('test1_cont_view', NULL, NULL);

SELECT count(*) FROM test1_cont_view;

\c :TEST_DBNAME :ROLE_SUPERUSER

SELECT chunk.schema_name|| '.' || chunk.table_name as "COMPRESSED_CHUNK_NAME"
FROM _timescaledb_catalog.chunk chunk
INNER JOIN _timescaledb_catalog.hypertable comp_hyper ON (chunk.hypertable_id = comp_hyper.id)
INNER JOIN _timescaledb_catalog.hypertable uncomp_hyper ON (comp_hyper.id = uncomp_hyper.compressed_hypertable_id)
WHERE uncomp_hyper.table_name like 'test1' ORDER BY chunk.id LIMIT 1
\gset

ALTER TABLE test1 OWNER TO :ROLE_DEFAULT_PERM_USER_2;

--make sure new owner is propagated down
SELECT a.rolname from pg_class c INNER JOIN pg_authid a ON(c.relowner = a.oid) WHERE c.oid = 'test1'::regclass;
SELECT a.rolname from pg_class c INNER JOIN pg_authid a ON(c.relowner = a.oid) WHERE c.oid = :'COMPRESSED_HYPER_NAME'::regclass;
SELECT a.rolname from pg_class c INNER JOIN pg_authid a ON(c.relowner = a.oid) WHERE c.oid = :'COMPRESSED_CHUNK_NAME'::regclass;

--
-- turn off compression
--

SELECT COUNT(*) AS count_compressed
FROM
(
SELECT decompress_chunk(chunk.schema_name|| '.' || chunk.table_name)
FROM _timescaledb_catalog.chunk chunk
INNER JOIN _timescaledb_catalog.hypertable hypertable ON (chunk.hypertable_id = hypertable.id)
WHERE hypertable.table_name like 'test1' and chunk.compressed_chunk_id IS NOT NULL ORDER BY chunk.id
)
AS sub;

select add_compression_policy('test1', interval '1 day');
\set ON_ERROR_STOP 0
ALTER table test1 set (timescaledb.compress='f');
\set ON_ERROR_STOP 1

select remove_compression_policy('test1');
ALTER table test1 set (timescaledb.compress='f');

--only one hypertable left
SELECT count(*) = 1 FROM _timescaledb_catalog.hypertable hypertable;
SELECT compressed_hypertable_id IS NULL FROM _timescaledb_catalog.hypertable hypertable WHERE hypertable.table_name like 'test1' ;
--no hypertable compression entries left
SELECT count(*) = 0 FROM _timescaledb_catalog.hypertable_compression;
--make sure there are no orphaned  _timescaledb_catalog.compression_chunk_size entries (should be 0)
SELECT count(*) as orphaned_compression_chunk_size
FROM _timescaledb_catalog.compression_chunk_size size
LEFT JOIN _timescaledb_catalog.chunk chunk ON (chunk.id = size.chunk_id)
WHERE chunk.id IS NULL;


--can turn compression back on
ALTER TABLE test1 set (timescaledb.compress, timescaledb.compress_segmentby = 'b', timescaledb.compress_orderby = '"Time" DESC');

SELECT COUNT(*) AS count_compressed
FROM
(
SELECT compress_chunk(chunk.schema_name|| '.' || chunk.table_name)
FROM _timescaledb_catalog.chunk chunk
INNER JOIN _timescaledb_catalog.hypertable hypertable ON (chunk.hypertable_id = hypertable.id)
WHERE hypertable.table_name like 'test1' and chunk.compressed_chunk_id IS NULL ORDER BY chunk.id
)
AS sub;

DROP TABLE test1 CASCADE;
DROP TABLESPACE tablespace1;

-- Triggers are NOT fired for compress/decompress
CREATE TABLE test1 ("Time" timestamptz, i integer);
SELECT table_name from create_hypertable('test1', 'Time', chunk_time_interval=> INTERVAL '1 day');
CREATE OR REPLACE FUNCTION test1_print_func()
RETURNS TRIGGER LANGUAGE PLPGSQL AS
$BODY$
BEGIN
   RAISE NOTICE ' raise notice test1_print_trigger called ';
   RETURN OLD;
END;
$BODY$;
CREATE TRIGGER test1_trigger
BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ON test1
FOR EACH STATEMENT EXECUTE FUNCTION test1_print_func();

INSERT INTO test1 SELECT generate_series('2018-03-02 1:00'::TIMESTAMPTZ, '2018-03-03 1:00', '1 hour') , 1 ;
-- add a row trigger too --
CREATE TRIGGER test1_trigger2
BEFORE INSERT OR UPDATE OR DELETE ON test1
FOR EACH ROW EXECUTE FUNCTION test1_print_func();
INSERT INTO test1 SELECT '2018-03-02 1:05'::TIMESTAMPTZ, 2;

ALTER TABLE test1 set (timescaledb.compress, timescaledb.compress_orderby = '"Time" DESC');

SELECT COUNT(*) AS count_compressed FROM
(
SELECT compress_chunk(chunk.schema_name|| '.' || chunk.table_name)
FROM _timescaledb_catalog.chunk chunk
INNER JOIN _timescaledb_catalog.hypertable hypertable ON (chunk.hypertable_id = hypertable.id)
WHERE hypertable.table_name like 'test1' and chunk.compressed_chunk_id IS NULL ORDER BY chunk.id) AS subq;

SELECT COUNT(*) AS count_compressed FROM
(
SELECT decompress_chunk(chunk.schema_name|| '.' || chunk.table_name)
FROM _timescaledb_catalog.chunk chunk
INNER JOIN _timescaledb_catalog.hypertable hypertable ON (chunk.hypertable_id = hypertable.id)
WHERE hypertable.table_name like 'test1'  ORDER BY chunk.id ) as subq;

DROP TABLE test1;

-- test disabling compression on hypertables with caggs and dropped chunks
-- github issue 2844
CREATE TABLE i2844 (created_at timestamptz NOT NULL,c1 float);
SELECT create_hypertable('i2844', 'created_at', chunk_time_interval => '6 hour'::interval);
INSERT INTO i2844 SELECT generate_series('2000-01-01'::timestamptz, '2000-01-02'::timestamptz,'1h'::interval);

CREATE MATERIALIZED VIEW test_agg WITH (timescaledb.continuous) AS SELECT time_bucket('1 hour', created_at) AS bucket, AVG(c1) AS avg_c1 FROM i2844 GROUP BY bucket;

ALTER TABLE i2844 SET (timescaledb.compress);

SELECT compress_chunk(show_chunks) AS compressed_chunk FROM show_chunks('i2844');
SELECT drop_chunks('i2844', older_than => '2000-01-01 18:00'::timestamptz);
SELECT decompress_chunk(show_chunks, if_compressed => TRUE) AS decompressed_chunks FROM show_chunks('i2844');

ALTER TABLE i2844 SET (timescaledb.compress = FALSE);

-- TEST compression alter schema tests
\ir include/compression_alter.sql

--TEST tablespaces for compressed chunks with attach_tablespace interface --
CREATE TABLE test2 (timec timestamptz, i integer, t integer);
SELECT table_name from create_hypertable('test2', 'timec', chunk_time_interval=> INTERVAL '1 day');

SELECT attach_tablespace('tablespace2', 'test2');

INSERT INTO test2 SELECT t,  gen_rand_minstd(), 22
FROM generate_series('2018-03-02 1:00'::TIMESTAMPTZ, '2018-03-02 13:00', '1 hour') t;

ALTER TABLE test2 set (timescaledb.compress, timescaledb.compress_segmentby = 'i', timescaledb.compress_orderby = 'timec');

SELECT relname FROM pg_class
WHERE reltablespace in
  ( SELECT oid from pg_tablespace WHERE spcname = 'tablespace2') ORDER BY 1;

-- test compress_chunk() with utility statement (SELECT ... INTO)
SELECT compress_chunk(ch) INTO compressed_chunks FROM show_chunks('test2') ch;
SELECT decompress_chunk(ch) INTO decompressed_chunks FROM show_chunks('test2') ch;

-- compress again
SELECT compress_chunk(ch) FROM show_chunks('test2') ch;

-- the chunk, compressed chunk + index + toast tables are in tablespace2 now .
-- toast table names differ across runs. So we use count to verify the results
-- instead of printing the table/index names
SELECT count(*) FROM (
SELECT relname FROM pg_class
WHERE reltablespace in
  ( SELECT oid from pg_tablespace WHERE spcname = 'tablespace2'))q;

DROP TABLE test2 CASCADE;
DROP TABLESPACE tablespace2;

-- Create a table with a compressed table and then delete the
-- compressed table and see that the drop of the hypertable does not
-- generate an error. This scenario can be triggered if an extension
-- is created with compressed hypertables since the tables are dropped
-- as part of the drop of the extension.
CREATE TABLE issue4140("time" timestamptz NOT NULL, device_id int);
SELECT create_hypertable('issue4140', 'time');
ALTER TABLE issue4140 SET(timescaledb.compress);
SELECT format('%I.%I', schema_name, table_name)::regclass AS ctable
FROM _timescaledb_catalog.hypertable
WHERE id = (SELECT compressed_hypertable_id FROM _timescaledb_catalog.hypertable WHERE table_name = 'issue4140') \gset
SELECT timescaledb_pre_restore();
DROP TABLE :ctable;
SELECT timescaledb_post_restore();
DROP TABLE issue4140;

-- github issue 5104
CREATE TABLE metric(
	time TIMESTAMPTZ NOT NULL,
	value DOUBLE PRECISION NOT NULL,
	series_id BIGINT NOT NULL);

SELECT create_hypertable('metric', 'time',
	chunk_time_interval => interval '1 h',
	create_default_indexes => false);

-- enable compression
ALTER TABLE metric set(timescaledb.compress,
    timescaledb.compress_segmentby = 'series_id, value',
    timescaledb.compress_orderby = 'time'
);

SELECT
      comp_hypertable.schema_name AS "COMP_SCHEMA_NAME",
      comp_hypertable.table_name AS "COMP_TABLE_NAME"
FROM _timescaledb_catalog.hypertable uc_hypertable
INNER JOIN _timescaledb_catalog.hypertable comp_hypertable ON (comp_hypertable.id = uc_hypertable.compressed_hypertable_id)
WHERE uc_hypertable.table_name like 'metric' \gset

-- get definition of compressed hypertable and notice the index
\d :COMP_SCHEMA_NAME.:COMP_TABLE_NAME

-- #5161 segmentby param

\d test1

CREATE MATERIALIZED VIEW test1_cont_view2
WITH (timescaledb.continuous,
      timescaledb.materialized_only=true
      )
AS SELECT time_bucket('1 hour', "Time") as t, SUM(intcol) as sum,txtcol
   FROM test1
   GROUP BY 1,txtcol WITH NO DATA;


ALTER MATERIALIZED VIEW test1_cont_view2 SET (
  timescaledb.compress = true,
  timescaledb.compress_segmentby = 'txtcol'
);

DROP TABLE metric CASCADE;
