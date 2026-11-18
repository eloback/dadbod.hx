;; Adapters: how to run a query against each kind of database with its own
;; command line client.
;;
;; Every adapter turns a parsed URL into an `invocation`: the client program,
;; its arguments and extra environment variables. The query is always fed to
;; the program on stdin, so adding a database means adding one function here.
;;
;; Passwords never go into the arguments, where `ps` would show them: they
;; are passed through the client's environment variable.
;;
;; An adapter refuses what it doesn't understand (a query parameter, a URL
;; without //) instead of dropping it: silently ignoring `?ssl-mode=REQUIRED`
;; would connect without the encryption that was asked for.
;;
;; Pure Steel, no Helix: unit-tested with `steel tests/unit.scm`.

(require "url.scm")

(provide url->invocation
         invocation
         invocation?
         invocation-programs
         invocation-args
         invocation-env
         supported-schemes)

;; programs  client names to look up on PATH; the first one found is run
;; args      list of strings
;; env       list of (name . value) pairs added to the child's environment
(struct invocation (programs args env))

(define (strip-leading-slash path)
  (if (starts-with? path "/")
      (substring path 1 (string-length path))
      path))

(define (password-env name url)
  (if (db-url-password url)
      (list (cons name (db-url-password url)))
      '()))

;; "postgres:app:secret@host/db" (the // forgotten) parses as a path, which
;; would put the password in the arguments and in the result's first line.
(define (require-authority url example)
  (unless (db-url-authority? url)
    (error (string-append (db-url-scheme url)
                          " URLs need the // after the scheme, like "
                          example))))

(define (refuse-query url)
  (when (db-url-query url)
    (error (string-append "query parameters (the part after '?') are not supported in "
                          (db-url-scheme url)
                          " URLs"))))

;; psql takes the whole URL, so every libpq parameter in the query string
;; (sslmode, options, ...) keeps working.
;;   -w                never prompt for a password: psql would open the
;;                     terminal Helix is drawing on
;;   ON_ERROR_STOP=1   stop at the first failing statement
(define (postgres url)
  (require-authority url "postgres://user@host/database, or postgres:///database")
  (invocation (list "psql")
              (list "-w" "-v" "ON_ERROR_STOP=1" "--dbname" (db-url-without-password url))
              (password-env "PGPASSWORD" url)))

;; --table gives the bordered output the client only uses on a terminal.
;; With a port, force TCP: for "localhost" the client would otherwise ignore
;; the port and use the default unix socket.
;; The database goes in --database=, not as a bare argument, so a name
;; starting with "-" can't be taken for an option.
;;
;; MariaDB ships its client as `mariadb` and, on some systems only, also as
;; `mysql`; MySQL only has `mysql`. So each scheme prefers its own name and
;; falls back to the other.
(define (mysql programs)
  (lambda (url)
    (require-authority url "mysql://user@host/database")
    (refuse-query url)
    (define database (strip-leading-slash (db-url-path url)))
    (invocation programs
                (append (list "--table")
                        (if (db-url-host url) (list "--host" (db-url-host url)) '())
                        (if (db-url-port url)
                            (list "--port" (number->string (db-url-port url)) "--protocol" "tcp")
                            '())
                        (if (db-url-user url) (list "--user" (db-url-user url)) '())
                        (if (string=? database "") '() (list (string-append "--database=" database))))
                (password-env "MYSQL_PWD" url))))

;; sqlite:notes.db (relative to Helix's working directory) or
;; sqlite:///home/me/notes.db (absolute).
;;   -bail   stop at the first failing statement
(define (sqlite url)
  (when (db-url-host url)
    (error (string-append "sqlite URLs have no host: use sqlite:relative/path.db or "
                          "sqlite:///absolute/path.db")))
  (refuse-query url)
  (define path (db-url-path url))
  (when (string=? path "")
    (error "sqlite URL has no file: use sqlite:relative/path.db or sqlite:///absolute/path.db"))
  (invocation (list "sqlite3")
              ;; "./-notes.db": a file name starting with "-" is not an option.
              (list "-bail" "-table" (if (starts-with? path "-") (string-append "./" path) path))
              '()))

(define adapters
  (list (cons "postgres" postgres)
        (cons "postgresql" postgres)
        (cons "mysql" (mysql (list "mysql" "mariadb")))
        (cons "mariadb" (mysql (list "mariadb" "mysql")))
        (cons "sqlite" sqlite)
        (cons "sqlite3" sqlite)))

(define supported-schemes (map car adapters))

;; Builds the invocation for a parsed URL. Raises an error with a message for
;; the user when the scheme has no adapter or the URL doesn't fit it.
(define (url->invocation url)
  (define adapter (assoc (db-url-scheme url) adapters))
  (unless adapter
    (error (string-append "no adapter for '"
                          (db-url-scheme url)
                          "' databases (supported: "
                          (string-join supported-schemes ", ")
                          ")")))
  ((cdr adapter) url))
