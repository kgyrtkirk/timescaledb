
begin;
    create temporary table stage as select * from :table_name order by time desc limit 1000;

    update stage set time = time + (select max(time)-min(time) from stage)+ INTERVAL '1 day';
commit;