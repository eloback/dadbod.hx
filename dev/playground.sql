-- Try the plugin against the playground database:
--
--   devenv up -d          start PostgreSQL with dev/seed.sql loaded
--   hx dev/playground.sql
--   :db-run               runs the whole file ($DATABASE_URL is set by devenv)
--
-- Select one statement (put the cursor on it and press `x`) and :db-run runs
-- only that.

select a.name, count(*) as books
from authors a
join books b on b.author_id = a.id
group by a.name
order by books desc, a.name;

select title, published
from books
where published < 1970
order by published;
