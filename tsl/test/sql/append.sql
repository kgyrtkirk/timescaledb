
select :step+1 as step \gset

-- create table stage as select * from :table_name order by time desc limit 1000;
-- update stage set time = time + (select max(time)-min(time) from stage)+ INTERVAL '1 day';

-- hex based ratio: 01 = 1/256, 8=1/2 ...
\set ratio '1'

create table stage as
select * from :table_name
    where md5(extract(epoch from time)::text) < :'ratio';

-- push records into the future
update stage set time = time + (select max(time)-min(time) from stage) + INTERVAL '1 us' + INTERVAL '1 day';

insert into :table_name select * from stage;

drop table stage;
