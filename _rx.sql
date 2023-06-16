
set enable_nestloop = false;
set parallel_tuple_cost =0;
set parallel_setup_cost = 0;

drop table if exists ct2;
create table ct2 (temp double precision);
insert into ct2 values (11.0),(0.1);
analyze ct2;

set enable_seqscan =false;
set enable_material =false;



drop table if exists vx;
create table vx as select 0 as v;

drop function if exists fun();

CREATE FUNCTION fun () RETURNS INTEGER AS 
$$
    DECLARE
        a integer;
        b integer;
    BEGIN
        select count(1) into a from vx;
        PERFORM  pg_sleep(.3);
        select count(1) into b from vx;
        RETURN b-a;
    END;
$$ LANGUAGE 'plpgsql'  STABLE STRICT PARALLEL SAFE;

\! psql tsdb -c 'select pg_sleep(.3);insert into vx values (1);' &

select fun();

-- CREATE OR REPLACE FUNCTION fun()
-- RETURNS INTeger 
-- LANGUAGE plpgsql AS
-- $BODY$

--     RETURN 0::int8;
-- $BODY$

DROP MATERIALIZED VIEW stock_candlestick_daily;
CREATE MATERIALIZED VIEW stock_candlestick_daily
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 day', "time") AS day,
  count(1) as cnt
FROM main_table
GROUP BY day
WITH NO DATA;

insert into vx  values(1);

--select _timescaledb_internal.cagg_watermark_materialized(37);
select mat_hypertable_id as cht from _timescaledb_catalog.continuous_agg \gset

select _timescaledb_internal.cagg_watermark_materialized(:cht);


BEGIN TRANSACTION ISOLATION LEVEL READ UNCOMMITTED ;
explain  analyze
SELECT device_id,count(1) FROM (
  SELECT * FROM main_table WHERE time < '2018-03-03 19:05:00'::text::timestamp
                            and time < _timescaledb_internal.to_timestamp_without_timezone(_timescaledb_internal.cagg_watermark_materialized(:cht))
  UNION ALL
  SELECT * FROM main_table WHERE time > '2018-03-03 19:05:00'::text::timestamp
                            and time > _timescaledb_internal.to_timestamp_without_timezone(_timescaledb_internal.cagg_watermark_materialized(:cht))
) q  join ct2 on (device_id > temp::text) group by device_id;

