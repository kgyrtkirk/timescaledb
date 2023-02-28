drop table if exists hourly ;
CREATE TABLE hourly (
    time timestamptz NOT NULL,
    signal smallint NOT NULL,
    value real,
    level_a integer,
    level_b smallint,
    level_c smallint,
    agg smallint
);

SELECT create_hypertable('hourly', 'time');

INSERT into hourly(time, signal,value, level_a, level_b, level_c, agg) values 
('2022-10-01T00:00:00Z', 2, 685, 1, -1, -1, 2 ),
('2022-10-01T00:00:00Z', 2, 686, 1, -1, -1, 3 ),
('2022-10-01T02:00:00Z', 2, 686, 1, -1, -1, 2 ),
('2022-10-01T02:00:00Z', 2, 687, 1, -1, -1, 3 ),
('2022-10-01T03:00:00Z', 2, 687, 1, -1, -1, 2 ),
('2022-10-01T03:00:00Z', 2, 688, 1, -1, -1, 3 );

SELECT
 time_bucket_gapfill('1 hour', time) as time,
 CASE WHEN agg in (0,3) THEN max(value) ELSE null END as max,
 CASE WHEN agg in (0,2) THEN min(value) ELSE null END as min,
agg
 FROM hourly WHERE agg in (0,2,3) and signal in (2) AND level_a = 1 AND level_b = -1 AND time >= '2022-10-01T00:00:00Z' AND time < '2022-10-01T05:59:59Z' 
 GROUP BY  1,agg order by 1,agg;
