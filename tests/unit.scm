;; Unit tests for the pure modules (no Helix needed):
;;
;;   steel tests/unit.scm        (or `test-unit` in the devenv shell)
;;
;; Exits non-zero when a test fails.

(require "steel/tests/unit-test.scm")
(require "../url.scm")
(require "../adapters.scm")
(require "../run.scm")
(require-builtin steel/time)

;; The message of the error `thunk` raises, or #f. Steel puts a space in front
;; of an error's message, so it is trimmed, as dadbod.scm does to show it.
(define (error-message thunk)
  (with-handler (lambda (err) (trim (error-object-message err)))
                (begin
                  (thunk)
                  #f)))

;; (scheme user password host port path query)
(define (parts text)
  (define url (parse-url text))
  (list (db-url-scheme url)
        (db-url-user url)
        (db-url-password url)
        (db-url-host url)
        (db-url-port url)
        (db-url-path url)
        (db-url-query url)))

(define (parse-error text)
  (error-message (lambda () (parse-url text))))

;; (programs args env)
(define (run-as text)
  (define inv (url->invocation (parse-url text)))
  (list (invocation-programs inv) (invocation-args inv) (invocation-env inv)))

(define (adapter-error text)
  (error-message (lambda () (run-as text))))

(define encode-hint "percent-encode / ? # @ and : in the user and password, like %2F for /")
(define port-error
  (string-append "database URL has an invalid port (if that is not a port: " encode-hint ")"))
(define at-error (string-append "database URL has an '@' after its host: " encode-hint))

;;; percent-decode

(check-equal? "decode: plain text is untouched" (percent-decode "plain") "plain")
(check-equal? "decode: escapes" (percent-decode "p%40ss%3Aword%2F") "p@ss:word/")
(check-equal? "decode: lowercase hex" (percent-decode "%2f") "/")
(check-equal? "decode: multi-byte UTF-8" (percent-decode "caf%C3%A9") "café")
(check-equal? "decode: plus is not a space" (percent-decode "a+b") "a+b")
(check-equal? "decode: a stray percent is kept" (percent-decode "100%") "100%")
(check-equal? "decode: non-hex after percent is kept" (percent-decode "%zz") "%zz")
(check-equal? "decode: invalid UTF-8 keeps the input" (percent-decode "%ff") "%ff")

;;; parse-url

(check-equal? "url: everything"
              (parts "postgres://app:s3cret@db.example.com:5433/shop?sslmode=require")
              (list "postgres" "app" "s3cret" "db.example.com" 5433 "/shop" "sslmode=require"))

(check-equal? "url: host only"
              (parts "postgres://localhost")
              (list "postgres" #f #f "localhost" #f "" #f))

(check-equal? "url: no authority, database only"
              (parts "postgres:///dadbod")
              (list "postgres" #f #f #f #f "/dadbod" #f))

(check-equal? "url: user without password"
              (parts "mysql://root@127.0.0.1:3307/app")
              (list "mysql" "root" #f "127.0.0.1" 3307 "/app" #f))

(check-equal? "url: scheme is lowercased"
              (db-url-scheme (parse-url "PostgreSQL://localhost/x"))
              "postgresql")

(check-equal? "url: surrounding whitespace is ignored"
              (parts "  sqlite:notes.db\n")
              (list "sqlite" #f #f #f #f "notes.db" #f))

(check-equal? "url: user, password and path are decoded"
              (parts "postgres://us%40er:p%40ss%3Aw%2Ford@host/my%20db")
              (list "postgres" "us@er" "p@ss:w/ord" "host" #f "/my db" #f))

(check-equal? "url: password with raw @ and :"
              (parts "postgres://app:p@ss:word@host/db")
              (list "postgres" "app" "p@ss:word" "host" #f "/db" #f))

(check-equal? "url: empty password is no password"
              (db-url-password (parse-url "postgres://app:@host/db"))
              #f)

(check-equal? "url: IPv6 host with port"
              (parts "postgres://app@[::1]:5432/db")
              (list "postgres" "app" #f "::1" 5432 "/db" #f))

(check-equal? "url: IPv6 host without port"
              (parts "postgres://[fe80::1]/db")
              (list "postgres" #f #f "fe80::1" #f "/db" #f))

(check-equal? "url: query without a path"
              (parts "postgres://host?sslmode=disable")
              (list "postgres" #f #f "host" #f "" "sslmode=disable"))

(check-equal? "url: opaque path" (parts "sqlite:data/notes.db") (list "sqlite" #f #f #f #f "data/notes.db" #f))

(check-equal? "url: opaque absolute path"
              (parts "sqlite:/var/lib/notes.db")
              (list "sqlite" #f #f #f #f "/var/lib/notes.db" #f))

(check-equal? "url: three slashes is an absolute path"
              (parts "sqlite:///var/lib/notes.db")
              (list "sqlite" #f #f #f #f "/var/lib/notes.db" #f))

(check-equal? "url: // makes an authority, even an empty one"
              (map (lambda (text) (db-url-authority? (parse-url text)))
                   (list "postgres://host/db" "postgres:///db" "sqlite:notes.db" "postgres:db"))
              (list #t #t #f #f))

(check-equal? "url: without-password drops only the password"
              (db-url-without-password
               (parse-url "postgres://app:s3cret@db.example.com:5433/shop?sslmode=require"))
              "postgres://app@db.example.com:5433/shop?sslmode=require")

(check-equal? "url: without-password keeps the encoding"
              (db-url-without-password (parse-url "postgres://us%40er:p%40ss@host/my%20db"))
              "postgres://us%40er@host/my%20db")

(check-equal? "url: without-password with nothing to drop"
              (db-url-without-password (parse-url "postgres:///dadbod"))
              "postgres:///dadbod")

(check-equal? "url: display drops the password and the query"
              (db-url-display
               (parse-url "postgres://app:s3cret@db.example.com:5433/shop?password=other"))
              "postgres://app@db.example.com:5433/shop")

(check-equal? "url: display of an opaque URL"
              (db-url-display (parse-url "sqlite:notes.db?mode=ro"))
              "sqlite:notes.db")

;; Errors. None of them quotes the URL: it can hold a password.

(check-equal? "url: no scheme is an error"
              (parse-error "just some text")
              "not a database URL: expected scheme://… or scheme:path")

(check-equal? "url: leading colon is an error"
              (parse-error ":memory:")
              "not a database URL: expected scheme://… or scheme:path")

(check-equal? "url: a raw / in the password is an error, not a host"
              (map parse-error
                   (list "postgres://app:12/34@host/db"
                         "mysql://app:se/cret@host/db"
                         "postgres://app:pa?ss@host/db"))
              (list at-error at-error at-error))

(check-equal? "url: a non-numeric port is an error that doesn't quote it"
              (parse-error "postgres://host:abc/db")
              port-error)

(check-equal? "url: ports are digits only"
              (map parse-error
                   (list "mysql://host:1e3/db"
                         "mysql://host:5432.0/db"
                         "mysql://host:#x1F90/db"
                         "mysql://host:+80/db"
                         "mysql://host:0/db"
                         "mysql://host:70000/db"
                         "mysql://host:123456789012345678901234567890/db"))
              (list port-error port-error port-error port-error port-error port-error port-error))

(check-equal? "url: unclosed bracket is an error"
              (parse-error "postgres://[::1/db")
              "database URL has an unclosed '[' in its host")

(check-equal? "url: an IPv6 address without brackets is an error"
              (map parse-error (list "mysql://::1/db" "mysql://::1:3306/db"))
              (list
               "database URL has several ':' in its host: write an IPv6 address in brackets, like [::1]:5432"
               "database URL has several ':' in its host: write an IPv6 address in brackets, like [::1]:5432"))

;;; adapters

(check-equal? "postgres: URL goes to --dbname without the password"
              (run-as "postgres://app:s3cret@db.example.com:5433/shop?sslmode=require")
              (list (list "psql")
                    (list "-w"
                          "-v"
                          "ON_ERROR_STOP=1"
                          "--dbname"
                          "postgres://app@db.example.com:5433/shop?sslmode=require")
                    (list (cons "PGPASSWORD" "s3cret"))))

(check-equal? "postgres: decoded password in the environment"
              (invocation-env (url->invocation (parse-url "postgres://app:p%40ss@host/db")))
              (list (cons "PGPASSWORD" "p@ss")))

(check-equal? "postgres: no password, no environment"
              (run-as "postgresql:///dadbod")
              (list (list "psql") (list "-w" "-v" "ON_ERROR_STOP=1" "--dbname" "postgresql:///dadbod") '()))

(check-equal? "postgres: without // is an error (the password would reach the arguments)"
              (adapter-error "postgres:app:secret@host/db")
              (string-append "postgres URLs need the // after the scheme, like "
                             "postgres://user@host/database, or postgres:///database"))

(check-equal? "mysql: every part"
              (run-as "mysql://root:s3cret@127.0.0.1:3307/app")
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
              (run-as "mysql://localhost/app")
              (list (list "mysql" "mariadb") (list "--table" "--host" "localhost" "--database=app") '()))

(check-equal? "mysql: no database"
              (run-as "mysql://root@db")
              (list (list "mysql" "mariadb") (list "--table" "--host" "db" "--user" "root") '()))

(check-equal? "mysql: a database starting with - is not an option"
              (invocation-args (url->invocation (parse-url "mysql://host/--defaults-file=x")))
              (list "--table" "--host" "host" "--database=--defaults-file=x"))

(check-equal? "mariadb: prefers the mariadb client"
              (run-as "mariadb://root@db/app")
              (list (list "mariadb" "mysql") (list "--table" "--host" "db" "--user" "root" "--database=app") '()))

(check-equal? "mysql: query parameters are refused, not dropped"
              (map adapter-error
                   (list "mysql://host/db?ssl-mode=REQUIRED" "mariadb://host/db?socket=/run/mysqld.sock"))
              (list "query parameters (the part after '?') are not supported in mysql URLs"
                    "query parameters (the part after '?') are not supported in mariadb URLs"))

(check-equal? "mysql: without // is an error"
              (adapter-error "mysql:app:secret@host/db")
              "mysql URLs need the // after the scheme, like mysql://user@host/database")

(check-equal? "sqlite: relative file"
              (run-as "sqlite:data/notes.db")
              (list (list "sqlite3") (list "-bail" "-table" "data/notes.db") '()))

(check-equal? "sqlite: absolute file"
              (run-as "sqlite3:///var/lib/notes.db")
              (list (list "sqlite3") (list "-bail" "-table" "/var/lib/notes.db") '()))

(check-equal? "sqlite: a file starting with - is not an option"
              (invocation-args (url->invocation (parse-url "sqlite:-version")))
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

(check-equal? "unknown scheme is an error"
              (adapter-error "oracle://host/db")
              (string-append "no adapter for 'oracle' databases (supported: "
                             "postgres, postgresql, mysql, mariadb, sqlite, sqlite3)"))

;;; run.scm, with `sh` standing in for a database client

(define scratch
  (string-append (trim-end-matches (with-handler (lambda (_) "/tmp") (env-var "TMPDIR")) "/")
                 "/dadbod-unit-"
                 (number->string (current-milliseconds))))
(create-directory! scratch)

(define (scratch-file name)
  (string-append scratch "/" name))

(define (remove-scratch-file! name)
  (with-handler (lambda (_) #f) (delete-file! (scratch-file name))))

(define (file-bytes name)
  (define port (open-input-file (scratch-file name)))
  (define content (read-port-to-bytes port))
  (close-input-port port)
  (bytes->list content))

(define (sh script env)
  (invocation (list "sh") (list "-c" script) env))

;; Runs `script` with `stdin` as its input: (exit-code stdout stderr).
(define (run-sh script stdin env)
  (write-file! (scratch-file "stdin") stdin)
  (remove-scratch-file! "stdout")
  (define code
    (run-invocation (sh script env) (scratch-file "stdin") (scratch-file "stdout") (scratch-file "stderr")))
  (list code (read-file (scratch-file "stdout")) (read-file (scratch-file "stderr"))))

(check-equal? "run: stdin, stdout, stderr and the exit code"
              (run-sh "cat; echo problem >&2; exit 3" "select 1;\n" '())
              (list 3 "select 1;\n" "problem\n"))

(check-equal? "run: success is exit code 0" (run-sh "true" "" '()) (list 0 "" ""))

(check-equal? "run: the environment reaches the client"
              (run-sh "printf %s \"$DADBOD_TEST_PASSWORD\"" "" (list (cons "DADBOD_TEST_PASSWORD" "p@ss word")))
              (list 0 "p@ss word" ""))

(check-equal? "run: a client killed by a signal has no exit code"
              (car (run-sh "kill -9 $$" "" '()))
              #f)

(check-equal? "run: stdout is appended to what the file holds"
              (begin
                (write-file! (scratch-file "stdin") "")
                (write-file! (scratch-file "stdout") "-- header\n")
                (run-invocation (sh "echo row" '())
                                (scratch-file "stdin")
                                (scratch-file "stdout")
                                (scratch-file "stderr"))
                (read-file (scratch-file "stdout")))
              "-- header\nrow\n")

(check-equal? "run: the first client on PATH is the one that runs"
              (begin
                (write-file! (scratch-file "stdin") "")
                (remove-scratch-file! "stdout")
                (run-invocation (invocation (list "no-such-database-client" "sh") (list "-c" "echo second") '())
                                (scratch-file "stdin")
                                (scratch-file "stdout")
                                (scratch-file "stderr"))
                (read-file (scratch-file "stdout")))
              "second\n")

(define (missing-client-error programs)
  (error-message (lambda ()
                   (run-invocation (invocation programs '() '())
                                   (scratch-file "stdin")
                                   (scratch-file "stdout")
                                   (scratch-file "stderr")))))

(check-equal? "run: a missing client is an error"
              (missing-client-error (list "no-such-database-client"))
              "'no-such-database-client' is not on PATH")

(check-equal? "run: all candidates missing is an error naming them"
              (missing-client-error (list "no-such-client-a" "no-such-client-b"))
              "none of 'no-such-client-a', 'no-such-client-b' is on PATH")

(check-equal? "failure-of: what each outcome means"
              (map failure-of (list 0 3 #f "'psql' is not on PATH"))
              (list #f
                    "the database client exited with code 3"
                    "the database client was killed by a signal"
                    "'psql' is not on PATH"))

;; Runs `script` as a whole run: (failure result-text query-file-left? stderr-file-left?).
(define (result-of inv)
  (write-file! (scratch-file "query") "select 1;\n")
  (define failure
    (run-to-result! inv "sqlite:test.db" (scratch-file "query") (scratch-file "result") (scratch-file "stderr")))
  (list failure
        (read-file (scratch-file "result"))
        (path-exists? (scratch-file "query"))
        (path-exists? (scratch-file "stderr"))))

(check-equal? "result: header, then stdout; the query and stderr files are removed"
              (result-of (sh "cat; echo '| 1 |'" '()))
              (list #f "-- sqlite:test.db\nselect 1;\n| 1 |\n" #f #f))

(check-equal? "result: stdout, then stderr, then what went wrong"
              (result-of (sh "echo before; echo 'no such table' >&2; exit 1" '()))
              (list "the database client exited with code 1"
                    (string-append "-- sqlite:test.db\n"
                                   "before\n"
                                   "no such table\n"
                                   "-- db-run: the database client exited with code 1\n")
                    #f
                    #f))

(check-equal? "result: stderr without a final newline gets one"
              (cadr (result-of (sh "printf 'cut off' >&2; exit 2" '())))
              "-- sqlite:test.db\ncut off\n-- db-run: the database client exited with code 2\n")

(check-equal? "result: a client that can't be started is reported in the result"
              (result-of (invocation (list "no-such-database-client") '() '()))
              (list "'no-such-database-client' is not on PATH"
                    "-- sqlite:test.db\n-- db-run: 'no-such-database-client' is not on PATH\n"
                    #f
                    #f))

;; 0xE9 alone is "é" in Latin-1 and invalid in UTF-8: the bytes must come
;; through as they are, on stdout and on stderr.
(check-equal? "result: output that is not valid UTF-8 is kept byte for byte"
              (begin
                (write-file! (scratch-file "query") "")
                (run-to-result! (sh "printf 'caf\\351\\n'; printf 'err\\351\\n' >&2" '())
                                "x"
                                (scratch-file "query")
                                (scratch-file "result")
                                (scratch-file "stderr"))
                (file-bytes "result"))
              (append (bytes->list (string->bytes "-- x\ncaf"))
                      (list 233 10)
                      (bytes->list (string->bytes "err"))
                      (list 233 10)))

(for-each remove-scratch-file! (list "stdin" "stdout" "stderr" "query" "result"))
(delete-directory! scratch)

;;; report

(define stats (get-test-stats))
(displayln "passed: " (hash-ref stats 'success-count) ", failed: " (hash-ref stats 'failure-count))
(unless (zero? (hash-ref stats 'failure-count))
  (error "unit tests failed"))
