{
  pkgs,
  lib,
  inputs,
  ...
}:

let
  system = pkgs.stdenv.hostPlatform.system;

  # The commit of steel-core that the pinned Helix is built with, read from
  # its Cargo.lock.
  steelInHelix =
    let
      lock = builtins.fromTOML (builtins.readFile "${inputs.helix-steel}/Cargo.lock");
      core = lib.findFirst (p: p.name == "steel-core") null lock.package;
    in
    lib.last (lib.splitString "#" core.source);

  # Helix with the Steel plugin system. The fork's own package builds the
  # default features only, and its perl grammar doesn't compile with C23
  # compilers (its own `bsearch` clashes with glibc's), so it is left out.
  hx =
    (inputs.helix-steel.packages.${system}.helix.override {
      includeGrammarIf = grammar: grammar.name != "perl";
    }).overrideAttrs
      {
        cargoBuildFeatures = [
          "git"
          "steel"
        ];
      };

  steel = inputs.steel.packages.${system}.steel;
in
{
  assertions = [
    {
      assertion = inputs.steel.rev == steelInHelix;
      message = ''
        devenv.yaml pins Steel at ${inputs.steel.rev}, but the pinned Helix is built with
        steel-core ${steelInHelix}. Set the `steel` input to that commit: the tools and
        the interpreter inside hx have to be the same Steel.
      '';
    }
  ];

  packages = [
    hx # the Steel-enabled Helix the tests drive
    steel # steel (tests/unit.sh), forge, steel-language-server
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
    description = "The boundary lint and the unit tests (no Helix needed)";
    exec = ''
      exec "$DEVENV_ROOT/tests/unit.sh" "$@"
    '';
  };

  scripts.test-e2e = {
    description = "Drive the commands in a real hx against temporary databases";
    exec = ''
      exec "$DEVENV_ROOT/tests/e2e.sh" "$@"
    '';
  };

  # `devenv test`
  enterTest = ''
    test-unit
    test-e2e
  '';
}
