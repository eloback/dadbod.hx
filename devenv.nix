{ pkgs, ... }:

{
  # The Steel-enabled `hx`, plus `steel` and `forge`, are NOT provided here:
  # they come from the system (the nixos flake pins the Helix fork and the
  # Steel version that must match it). This shell adds the database clients
  # the adapters call, and a playground database.

  packages = [
    pkgs.sqlite # sqlite3, for the sqlite adapter
    pkgs.mariadb # mariadb client and server, for the mysql adapter and its test
    pkgs.tmux # tests/e2e.sh drives hx in an isolated tmux
  ];

  # A playground database: `devenv up`, then open dev/playground.sql and run
  # :db-run. Postgres listens on a unix socket only (PGHOST is exported by
  # devenv), so DATABASE_URL needs no host.
  services.postgres = {
    enable = true;
    listen_addresses = "";
    initialDatabases = [
      {
        name = "dadbod";
        schema = ./dev/seed.sql;
      }
    ];
  };

  env.DATABASE_URL = "postgres:///dadbod";

  scripts.test-unit = {
    description = "Unit tests for the URL parser and the adapters (needs `steel`)";
    exec = ''
      cd "$DEVENV_ROOT" && exec steel tests/unit.scm
    '';
  };

  scripts.test-e2e = {
    description = "Drive :db-run in a real hx against temporary databases";
    exec = ''
      exec "$DEVENV_ROOT/tests/e2e.sh" "$@"
    '';
  };

  enterShell = ''
    for tool in hx steel; do
      command -v "$tool" >/dev/null || echo "dadbod.hx: '$tool' is not on PATH (it comes from the system, not this shell)" >&2
    done
  '';

  # `devenv test`
  enterTest = ''
    test-unit
    test-e2e
  '';
}
