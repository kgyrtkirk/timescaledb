drop table main_table cascade;
CREATE TABLE main_table AS
SELECT '2011-11-11 11:11:11'::timestamptz AS time, 'foo' AS device_id limit 0;

SELECT create_hypertable('main_table', 'time', chunk_time_interval => interval '12 hour', migrate_data => TRUE);

ALTER TABLE main_table SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'device_id',
    timescaledb.compress_orderby = '');

INSERT INTO main_table SELECT t, 'dev1'  FROM generate_series('2018-03-02 1:00'::TIMESTAMPTZ, '2018-03-05 3:00', '1 hour') t;


insert into main_table select m1.* from main_table m1 join main_table m2  on(true);

insert into main_table select m1.* from main_table m1 join main_table m2  on(true) limit 600000;
