\set ON_ERROR_STOP 1

\set table_name readings
\set source_schema devices_1

select count(1) as schema_exists from information_schema.schemata where schema_name = :'source_schema' \gset
select :'schema_exists';
\if :schema_exists
-- already loaded
\else
begin;
    \set source_schema devices_load
    drop schema if exists :source_schema cascade;
    create schema :source_schema;
    set search_path=:source_schema,public;
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
    alter schema :source_schema rename to devices_1;
commit;
\endif
