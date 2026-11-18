-- Sample data for the playground database (devenv.nix, services.postgres).
create table authors (
  id   serial primary key,
  name text not null
);

create table books (
  id        serial primary key,
  author_id integer not null references authors (id),
  title     text not null,
  published integer
);

insert into authors (name) values
  ('Ursula K. Le Guin'),
  ('Stanisław Lem'),
  ('Octavia E. Butler');

insert into books (author_id, title, published) values
  (1, 'The Left Hand of Darkness', 1969),
  (1, 'The Dispossessed', 1974),
  (2, 'Solaris', 1961),
  (2, 'The Cyberiad', 1965),
  (3, 'Kindred', 1979);
