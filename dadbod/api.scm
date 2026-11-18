;; dadbod's API for other plugins and for init.scm: the one file of dadbod
;; another plugin requires, dadbod-ui first of all (tests/lint.sh checks that
;; it requires nothing else of dadbod).
;;
;;   (require "dadbod/dadbod/api.scm")       from init.scm or an installed plugin
;;   (require "../dadbod/api.scm")           from dadbod-ui/, in this repository
;;
;; Both name the same file, so both get the same dadbod: the database chosen
;; in one plugin is the one the other runs against.
;;
;; A "database" below is what the user would type after :db-run: a URL, or
;; the name of a connection. It can hold a password: show it only through
;; dadbod-display.
;;
;; Everything here is called on the main thread and raises an error with a
;; message for the user when it can't do what was asked.

(require "core/adapter.scm")
(require "core/adapters.scm")
(require "core/connections.scm")
(require "hx/commands.scm")

(provide dadbod-connections!
         dadbod-connection-names
         dadbod-connection-source
         dadbod-add-connection!
         dadbod-current
         dadbod-use!
         dadbod-use-for-file!
         dadbod-database-of-file
         dadbod-database-of-file!
         dadbod-display
         dadbod-supported-schemes
         dadbod-adapter-name
         dadbod-tables-sql
         dadbod-helpers
         dadbod-helper-sql
         dadbod-run!
         dadbod-query!
         dadbod-cancel!
         dadbod-on-event!
         dadbod-not-a-query!)

;;; Connections

;; Defines connections from init.scm: name and reference alternating.
;;
;;   (dadbod-connections! "dev"  "postgres:///shop_dev"
;;                        "prod" "!pass show databases/shop")
;;
;; A reference is a URL, $VARIABLE (an environment variable holding the
;; URL) or !command (a command printing it). The same can be written in the
;; connections files; see the README.
(define (dadbod-connections! . names-and-references)
  (define (pairs rest)
    (cond
      [(null? rest) '()]
      [(null? (cdr rest)) (error "dadbod-connections!: a name without a reference")]
      [else (cons (cons (car rest) (cadr rest)) (pairs (cddr rest)))]))
  (register-connections! (pairs names-and-references)))

;; The names of every connection there is, in the order they are defined.
(define (dadbod-connection-names)
  (map connection-name (all-connections)))

;; Where the connection `name` is defined (a file's path, "init.scm", or
;; "$DB_UI_NAME" for the environment), or #f when there is none by that
;; name. The project's file is <working directory>/.helix/dadbod-connections.
(define (dadbod-connection-source name)
  (define found (find-connection (all-connections) name))
  (and found (connection-source found)))

;; Adds a connection to the user's connections file.
(define (dadbod-add-connection! name reference)
  (save-connection! name reference))

;;; Which database

;; The database :db-run would run against in the focused buffer now, or #f:
;; the buffer's, else the one used last, else $DATABASE_URL.
(define (dadbod-current)
  (current-url))

;; Makes `database` the focused buffer's, and the one used from now on.
(define (dadbod-use! database)
  (use-url! database))

;; Makes `database` the one of the file at `path`, open or not, and of
;; nothing else.
(define (dadbod-use-for-file! path database)
  (use-for-path! path database))

;; The database :db-run would use in the file at `path`, or #f.
(define (dadbod-database-of-file path)
  (database-of-path path))

;; Tells dadbod which database files belong to: `asker` takes a file's path
;; and returns a database, or #f for a file that isn't its own. It is asked
;; when nothing was chosen for the file's buffer, each time a query runs, so
;; it has to be quick and must not look anything up.
(define (dadbod-database-of-file! asker)
  (database-of-file! asker))

;; `database` as it can be shown: a connection's name, or a URL without its
;; password and parameters. Looks nothing up.
(define (dadbod-display database)
  (database-display database))

;;; What is known about the database
;;
;; These look a connection up the first time they are asked about it (its
;; command may run), and not again.

;; The URL schemes there is an adapter for, like "postgres" and "sqlite".
(define (dadbod-supported-schemes)
  supported-schemes)

;; The kind of database, like "PostgreSQL".
(define (dadbod-adapter-name database)
  (adapter-name (adapter-of database)))

;; SQL that lists the database's tables and views, one per row: a bare name
;; for the default schema, schema.table otherwise. For dadbod-query!.
(define (dadbod-tables-sql database)
  (adapter-tables (adapter-of database)))

;; The names of the ready-made queries about a table, in the order to offer
;; them: "List", "Columns", ...
(define (dadbod-helpers database)
  (map car (adapter-helpers (adapter-of database))))

;; The SQL of the helper `helper` for `table` (a name as the tables query
;; gave it).
(define (dadbod-helper-sql database helper table)
  (define a (adapter-of database))
  (define found (assoc helper (adapter-helpers a)))
  (unless found
    (error (string-append "no helper called '" helper "'")))
  (expand-helper (cdr found) table (adapter-default-schema a) (adapter-mark a)))

;;; Running

;; Runs `sql` against `database` and shows the result in the result split,
;; exactly as :db-run does for a buffer. Returns the run's id.
(define (dadbod-run! database sql)
  (run-sql! database sql))

;; Runs `sql` against `database` without showing anything, for a plugin that
;; wants to read the answer itself (a list of tables, say). Returns the
;; run's id.
;;
;; The output is what a program reads easily: one row per line, no headers
;; or borders, columns separated the way the client does it (| for
;; PostgreSQL and SQLite, a tab for MySQL/MariaDB). The clients don't escape
;; a separator or a newline inside a value: ask for one column per query, or
;; for values that can't hold them.
;;
;; When the query is done, `callback` is called on the main thread with
;;   failure      what went wrong, as text, or #f
;;   stdout-file  the client's standard output
;;   stderr-file  the client's error output
;; Both files are deleted when it returns, and are not necessarily UTF-8.
(define (dadbod-query! database sql callback)
  (query-sql! database sql callback))

;; Asks the database to cancel the run `id`. Returns whether it was still
;; running and could be told.
(define (dadbod-cancel! id)
  (cancel-id! id))

;;; Events

;; Calls `listener` with each event from now on, a list:
;;   (database-changed)            another database is in use
;;   (connections-changed)         a connection was added
;;   (run-finished id failure)     a run ended; failure is text or #f
(define (dadbod-on-event! listener)
  (listen! listener))

;; Keeps :db-run from running a buffer that isn't a query. `why-not` is
;; called before each :db-run, with the buffer to run focused: when it
;; returns text, that is the error shown and nothing runs; #f lets it run.
(define (dadbod-not-a-query! why-not)
  (not-a-query! why-not))
