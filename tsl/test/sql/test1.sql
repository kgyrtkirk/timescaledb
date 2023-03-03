
\set dataset devices_1.csv
\set dataset devices_1.sql
\set table_name readings

\i devices_1.sql
\set current_mode normal

-- create fresh schema for current test
drop schema if exists :current_mode cascade;
create schema :current_mode;
set search_path=:current_mode,public;

\i load.sql
\i append.sql



