
select  :'current_mode' = 'normal' as t_normal,
        :'current_mode' = 'hyper' as t_hyper,
        :'current_mode' = 'compressed' as t_compressed
        \gset

-- :RESET_STATE

\set interval_1 '1000 second'
\set interval_2 '10000 second'

drop schema if exists :current_mode cascade;
create schema :current_mode;
set search_path=:current_mode,public;

CREATE TABLE conditions (
    t timestamp with time ZONE NOT NULL,
    temperature NUMERIC
);

\if :t_normal
\else
    SELECT create_hypertable('conditions', 't', chunk_time_interval => INTERVAL '10 day');
\endif

INSERT INTO conditions (t, temperature)
SELECT
    generate_series('2022-01-01 00:00:00-00'::timestamptz, '2022-01-31 23:59:59-00'::timestamptz, :'interval_1'),
    0.25;

\if :t_compressed
    ALTER TABLE conditions SET (timescaledb.compress);
    select compress_chunk(show_chunks('conditions'));
\endif

INSERT INTO conditions (t, temperature)
SELECT
    generate_series('2022-01-11 00:00:00-00'::timestamptz, '2022-01-21 23:59:59-00'::timestamptz, :'interval_2'),
    0.1;


INSERT INTO conditions (t, temperature)
VALUES 
('2022-01-12 00:00:00-00',1.0),
('2022-01-12 00:00:00-00',1.0);



\if :{?last_mode}
select :'current_mode' || '<>' || :'last_mode';
    (
            select count(1) over (partition by c),* from :current_mode.conditions c
        except 
            select count(1) over (partition by c),* from :last_mode.conditions c
    )
    union all
    (
            select count(1) over (partition by c),* from :last_mode.conditions c
        except 
            select count(1) over (partition by c),* from :current_mode.conditions c
    )
\endif

\set last_mode :current_mode

