
select  :'current_mode' = 'normal' as t_normal,
        :'current_mode' = 'hyper' as t_hyper,
        :'current_mode' = 'compressed' as t_compressed
        \gset

drop schema if exists :current_mode cascade;
create schema :current_mode;
set search_path=:current_mode,public;

\i devices.sql
\COPY readings FROM devices_small_readings.csv CSV
\COPY device_info FROM devices_small_device_info.csv CSV

\if :t_compressed
    ALTER TABLE readings SET (timescaledb.compress);
    select compress_chunk(show_chunks('readings'));
\endif

insert into   readings select * from readings;

\if :{?last_mode}
select :'current_mode' || '<>' || :'last_mode';
-- \set current_mode compressed
-- \set last_mode normal

\o _cmp1
explain analyze
    (
            select count(1) over (partition by c),* from :current_mode.readings c
        except 
            select count(1) over (partition by c),* from :last_mode.readings c
    )
    union all
    (
            select count(1) over (partition by c),* from :last_mode.readings c
        except 
            select count(1) over (partition by c),* from :current_mode.readings c
    );
-- 74s
\o _cmp2

explain analyze
with
    c as (select count(1) over (partition by c),* from :current_mode.readings c),
    l as (select count(1) over (partition by c),* from :last_mode.readings c)
(
        select * from c
    except
        select * from l
)
union all
(
        select * from l
    except
        select * from c
);
\o

\endif

\set last_mode :current_mode
