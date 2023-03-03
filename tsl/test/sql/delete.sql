
select :step+1 as step \gset

\set ratio '1'

delete from :table_name
    where md5(extract(epoch from time)::text || :step) < :'ratio';

