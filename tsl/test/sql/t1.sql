
create schema :current_mode;
set search_path=:current_mode;

CREATE TABLE conditions (
    t timestamp with time ZONE NOT NULL,
    temperature NUMERIC
);

\if :t_normal
\else
    SELECT create_hypertable('conditions', 't', chunk_time_interval => INTERVAL '1 hour');
\endif

\if :t_compressed
    ALTER TABLE conditions SET (timescaledb.compress);
\endif

:SAVE_STATE
