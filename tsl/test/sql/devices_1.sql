\set ON_ERROR_STOP 1

\set table_name readings
\set current_mode devices_1

select count(1) as schema_exists from information_schema.schemata where schema_name = :'current_mode' \gset
select :'schema_exists';
\if :schema_exists
-- already loaded
\else
begin;
    \set current_mode devices_load
    drop schema if exists :current_mode cascade;
    create schema :current_mode;
    set search_path=:current_mode,public;
    DROP TABLE IF EXISTS "device_info";
    CREATE TABLE "device_info"(
        device_id     TEXT,
        api_version   TEXT,
        manufacturer  TEXT,
        model         TEXT,
        os_name       TEXT
    );

    DROP TABLE IF EXISTS "readings";
    CREATE TABLE "readings"(
        time  TIMESTAMP WITH TIME ZONE NOT NULL,
        device_id  TEXT,
        battery_level  DOUBLE PRECISION,
        battery_status  TEXT,
        battery_temperature  DOUBLE PRECISION,
        bssid  TEXT,
        cpu_avg_1min  DOUBLE PRECISION,
        cpu_avg_5min  DOUBLE PRECISION,
        cpu_avg_15min  DOUBLE PRECISION,
        mem_free  DOUBLE PRECISION,
        mem_used  DOUBLE PRECISION,
        rssi  DOUBLE PRECISION,
        ssid  TEXT
    );
    CREATE INDEX ON "readings"(time DESC);
    CREATE INDEX ON "readings"(device_id, time DESC);
    -- 86400000000 is in usecs and is equal to 1 day
    SELECT create_hypertable('readings', 'time', chunk_time_interval => 86400000000);
    \COPY readings FROM devices_1.csv CSV
    \COPY device_info FROM devices_small_device_info.csv CSV
    alter schema :current_mode rename to devices_1;
commit;
\endif
