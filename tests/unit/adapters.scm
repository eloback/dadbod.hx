;; dadbod/core/adapters.scm and dadbod/core/adapters/*.scm
;;
;; First the contract every adapter has to keep, checked for each registered
;; adapter from one table of sample URLs; then each adapter's own details.

(require "steel/tests/unit-test.scm")
(require "lib.scm")
(require "../../dadbod/core/url.scm")
(require "../../dadbod/core/adapter.scm")
(require "../../dadbod/core/adapters.scm")

;; (programs args env)
(define (run-as text mode)
  (define inv (url->invocation (parse-url text) mode))
  (list (invocation-programs inv) (invocation-args inv) (invocation-env inv)))

(define (args-of text mode)
  (invocation-args (url->invocation (parse-url text) mode)))

(define (adapter-error text)
  (error-message (lambda () (run-as text 'table))))

;;; The contract

(define password "s3cr3t-PW")

;; adapter name -> sample URLs. A new adapter needs a row here: the contract
;; fails for an adapter without one.
(define samples
  (hash "PostgreSQL"
        (list (string-append "postgres://app:" password "@db.example.com:5433/shop")
              (string-append "postgresql://app:" password "@localhost/shop")
              "postgres:///shop")
        "MySQL/MariaDB"
        (list (string-append "mysql://app:" password "@db.example.com:3307/shop")
              (string-append "mariadb://app:" password "@localhost/shop")
              "mysql://localhost")
        "SQLite"
        (list "sqlite:data/shop.db" "sqlite3:///var/lib/shop.db")))

(define (has-password? text)
  (string-contains? text password))

;; What `text` breaks of the contract, as a list of complaints.
(define (violations text)
  (define url (parse-url text))
  (define table (url->invocation url 'table))
  (define plain (url->invocation url 'plain))
  (define (check inv)
    (append (if (and (list? (invocation-programs inv))
                     (not (null? (invocation-programs inv)))
                     (null? (filter (lambda (p) (string=? p "")) (invocation-programs inv))))
                '()
                (list "no client to run"))
            (if (null? (filter has-password? (invocation-args inv)))
                '()
                (list "the password is in the arguments"))
            (if (or (not (db-url-password url))
                    (member password (map cdr (invocation-env inv))))
                '()
                (list "the password is not in the environment"))))
  (append (check table)
          (check plain)
          (if (has-password? (db-url-display url)) (list "the password is in the display form") '())
          (if (equal? (invocation-args table) (invocation-args plain))
              (list "'plain and 'table run the same command")
              '())))

;; A parameter the adapter can't know is passed on to the client whole or
;; refused, never dropped.
(define (drops-unknown-parameter? text)
  (define with-parameter (string-append text "?zz_unknown=1"))
  (with-handler (lambda (_) #f)
                (null? (filter (lambda (arg) (string-contains? arg "zz_unknown=1"))
                               (args-of with-parameter 'table)))))

(for-each
 (lambda (a)
   (define name (adapter-name a))
   (define urls (or (hash-try-get samples name) '()))
   (check-equal? (string-append "contract: " name " has sample URLs in this file") (null? urls) #f)
   (check-equal? (string-append "contract: " name " has a sample for each of its schemes")
                 (filter (lambda (scheme)
                           (null? (filter (lambda (text) (equal? (db-url-scheme (parse-url text)) scheme))
                                          urls)))
                         (adapter-schemes a))
                 '())
   (check-equal? (string-append "contract: " name " handles its own schemes")
                 (map (lambda (text) (adapter-name (adapter-for (parse-url text)))) urls)
                 (map (lambda (_) name) urls))
   (for-each (lambda (text)
               (check-equal? (string-append "contract: " name ": " (db-url-display (parse-url text)))
                             (violations text)
                             '())
               (check-equal? (string-append "contract: "
                                            name
                                            " doesn't drop a parameter: "
                                            (db-url-display (parse-url text)))
                             (drops-unknown-parameter? text)
                             #f))
             urls))
 adapters)

(check-equal? "registry: the schemes, in order"
              supported-schemes
              (list "postgres" "postgresql" "mysql" "mariadb" "sqlite" "sqlite3"))

(check-equal? "registry: unknown scheme is an error"
              (adapter-error "oracle://host/db")
              (string-append "no adapter for 'oracle' databases (supported: "
                             "postgres, postgresql, mysql, mariadb, sqlite, sqlite3)"))

;;; PostgreSQL

(check-equal? "postgres: URL goes to --dbname without the password"
              (run-as "postgres://app:s3cret@db.example.com:5433/shop?sslmode=require" 'table)
              (list (list "psql")
                    (list "-w"
                          "-v"
                          "ON_ERROR_STOP=1"
                          "--dbname"
                          "postgres://app@db.example.com:5433/shop?sslmode=require")
                    (list (cons "PGPASSWORD" "s3cret"))))

(check-equal? "postgres: decoded password in the environment"
              (invocation-env (url->invocation (parse-url "postgres://app:p%40ss@host/db") 'table))
              (list (cons "PGPASSWORD" "p@ss")))

(check-equal? "postgres: no password, no environment"
              (run-as "postgresql:///dadbod" 'table)
              (list (list "psql") (list "-w" "-v" "ON_ERROR_STOP=1" "--dbname" "postgresql:///dadbod") '()))

(check-equal? "postgres: plain output is unaligned rows only"
              (args-of "postgres:///dadbod" 'plain)
              (list "-w" "-v" "ON_ERROR_STOP=1" "-A" "-t" "-q" "-X" "--dbname" "postgres:///dadbod"))

(check-equal? "postgres: a password as a parameter is refused (it would be in the arguments)"
              (map adapter-error (list "postgres://app@h/db?password=zzz" "postgres://app@h/db?sslmode=require&SSLPassword=y"))
              (list "give the password as postgres://user:password@…, not as a parameter: there it would show in the process list"
                    "give the password as postgres://user:password@…, not as a parameter: there it would show in the process list"))

(check-equal? "postgres: without // is an error (the password would reach the arguments)"
              (adapter-error "postgres:app:secret@host/db")
              (string-append "postgres URLs need the // after the scheme, like "
                             "postgres://user@host/database, or postgres:///database"))

;;; MySQL/MariaDB

(check-equal? "mysql: every part"
              (run-as "mysql://root:s3cret@127.0.0.1:3307/app" 'table)
              (list (list "mysql" "mariadb")
                    (list "--table"
                          "--host"
                          "127.0.0.1"
                          "--port"
                          "3307"
                          "--protocol"
                          "tcp"
                          "--user"
                          "root"
                          "--database=app")
                    (list (cons "MYSQL_PWD" "s3cret"))))

(check-equal? "mysql: host only keeps the client's default protocol"
              (run-as "mysql://localhost/app" 'table)
              (list (list "mysql" "mariadb") (list "--table" "--host" "localhost" "--database=app") '()))

(check-equal? "mysql: no database"
              (run-as "mysql://root@db" 'table)
              (list (list "mysql" "mariadb") (list "--table" "--host" "db" "--user" "root") '()))

(check-equal? "mysql: plain output is tab-separated rows only"
              (args-of "mysql://db/app" 'plain)
              (list "--batch" "--skip-column-names" "--host" "db" "--database=app"))

(check-equal? "mysql: a database starting with - is not an option"
              (args-of "mysql://host/--defaults-file=x" 'table)
              (list "--table" "--host" "host" "--database=--defaults-file=x"))

(check-equal? "mariadb: prefers the mariadb client"
              (run-as "mariadb://root@db/app" 'table)
              (list (list "mariadb" "mysql") (list "--table" "--host" "db" "--user" "root" "--database=app") '()))

(check-equal? "mysql: listed parameters become the client's options"
              (args-of "mysql://app@db/shop?ssl-mode=REQUIRED&ssl-ca=%2Fetc%2Fca.pem" 'table)
              (list "--table" "--host" "db" "--user" "app" "--ssl-mode=REQUIRED" "--ssl-ca=/etc/ca.pem" "--database=shop"))

(check-equal? "mysql: true and false switch an option on and off"
              (args-of "mariadb://db/shop?ssl=true&ssl-verify-server-cert=false" 'table)
              (list "--table" "--host" "db" "--ssl" "--skip-ssl-verify-server-cert" "--database=shop"))

(check-equal? "mysql: --login-path goes first, where the client wants it"
              (args-of "mysql:///shop?ssl=true&login-path=prod" 'table)
              (list "--login-path=prod" "--table" "--ssl" "--database=shop"))

(check-equal? "mysql: a socket as a parameter"
              (args-of "mysql://app@/shop?socket=/run/mysqld/mysqld.sock" 'table)
              (list "--table" "--user" "app" "--socket=/run/mysqld/mysqld.sock" "--database=shop"))

(check-equal? "mysql: a socket where the host goes, percent-encoded"
              (args-of "mysql://app@%2Frun%2Fmysqld%2Fmysqld.sock/shop" 'table)
              (list "--table" "--socket=/run/mysqld/mysqld.sock" "--user" "app" "--database=shop"))

(check-equal? "mysql: an option that takes a value needs one, or it would swallow the next argument"
              (map adapter-error (list "mysql://h/db?ssl-ca" "mysql://h/db?socket=" "mysql://h/db?ssl=maybe"))
              (list "the parameter 'ssl-ca' needs a value"
                    "the parameter 'socket' needs a value"
                    "the parameter 'ssl' is true or false"))

(check-equal? "mysql: a socket where the host goes, with a port, is an error"
              (adapter-error "mysql://u@%2Ftmp%2Fm.sock:3306/db")
              "a mysql URL names a socket or a port, not both")

(check-equal? "mysql: a parameter that isn't listed is refused, not dropped"
              (adapter-error "mysql://host/db?init-command=drop")
              (string-append "'init-command' is not a parameter mysql URLs support (ssl, ssl-ca, ssl-capath, "
                             "ssl-cert, ssl-cipher, ssl-key, ssl-mode, ssl-verify-server-cert, protocol, "
                             "socket, default-character-set, login-path)"))

(check-equal? "mysql: without // is an error"
              (adapter-error "mysql:app:secret@host/db")
              "mysql URLs need the // after the scheme, like mysql://user@host/database")

;;; What an adapter knows about the catalog

(check-equal? "catalog: every adapter lists tables and offers a List helper first"
              (map (lambda (a)
                     (list (string? (adapter-tables a)) (car (car (adapter-helpers a)))))
                   adapters)
              (list (list #t "List") (list #t "List") (list #t "List")))

(define all-placeholders "{table} / {table-literal} / {schema} / {name}")

(check-equal? "helper: a bare table is in the default schema, and quoted"
              (expand-helper all-placeholders "books" "public" "\"")
              "\"public\".\"books\" / \"public\".\"books\" / public / books")

(check-equal? "helper: a qualified table names its schema; case is kept by the quotes"
              (expand-helper all-placeholders "sales.Orders" "public" "\"")
              "\"sales\".\"Orders\" / \"sales\".\"Orders\" / sales / Orders")

(check-equal? "helper: without schemas a dot is part of the name"
              (expand-helper all-placeholders "my.table" #f "`")
              "`my.table` / `my.table` /  / my.table")

(check-equal? "helper: a name can't break out of its quotes, as an identifier or in a string"
              (list (expand-helper "select * from {table}; -- '{name}' '{table-literal}'" "a\"b'c" #f "\"")
                    (expand-helper "show columns from {table};" "x`; drop table y; --" #f "`"))
              (list "select * from \"a\"\"b'c\"; -- 'a\"b''c' '\"a\"\"b''c\"'"
                    "show columns from `x``; drop table y; --`;"))

(check-equal? "helper: every placeholder of every helper is one of the three"
              (filter (lambda (sql) (string-contains? sql "{"))
                      (apply append
                             (map (lambda (a)
                                    (map (lambda (h) (expand-helper (cdr h) "s.t" "public" "\"")) (adapter-helpers a)))
                                  adapters)))
              '())

(check-equal? "helper: names the quoting can't be trusted with are refused"
              (map (lambda (name) (error-message (lambda () (expand-helper "select * from {table};" name "public" "\""))))
                   (list "x\\' ; drop table y; --" "a\nb" "x{schema}" "tab\there"))
              (let ([refused (string-append "this table's name has a backslash, a brace or a control "
                                            "character in it: the helpers don't run on such names")])
                (list refused refused refused refused)))

;;; SQLite

(check-equal? "sqlite: relative file"
              (run-as "sqlite:data/notes.db" 'table)
              (list (list "sqlite3") (list "-bail" "-table" "data/notes.db") '()))

(check-equal? "sqlite: absolute file"
              (run-as "sqlite3:///var/lib/notes.db" 'table)
              (list (list "sqlite3") (list "-bail" "-table" "/var/lib/notes.db") '()))

(check-equal? "sqlite: plain output is rows only"
              (args-of "sqlite:notes.db" 'plain)
              (list "-bail" "-list" "-noheader" "notes.db"))

(check-equal? "sqlite: a file starting with - is not an option"
              (args-of "sqlite:-version" 'table)
              (list "-bail" "-table" "./-version"))

(check-equal? "sqlite: a host is an error"
              (adapter-error "sqlite://notes.db")
              "sqlite URLs have no host: use sqlite:relative/path.db or sqlite:///absolute/path.db")

(check-equal? "sqlite: no file is an error"
              (adapter-error "sqlite:")
              "sqlite URL has no file: use sqlite:relative/path.db or sqlite:///absolute/path.db")

(check-equal? "sqlite: query parameters are refused, not dropped"
              (adapter-error "sqlite:notes.db?mode=ro")
              "query parameters (the part after '?') are not supported in sqlite URLs")

(finish-tests!)
