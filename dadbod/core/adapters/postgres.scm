;; PostgreSQL, through psql.
;;
;; psql takes the whole URL, so every libpq parameter in the query string
;; (sslmode, options, host=/socket/dir, ...) keeps working.
;;   -w                never prompt for a password: psql would open the
;;                     terminal Helix is drawing on
;;   ON_ERROR_STOP=1   stop at the first failing statement
;;   -A -t -q -X       ('plain) unaligned rows, no header or footer, and no
;;                     ~/.psqlrc: a `\timing on` there would add lines a
;;                     program doesn't expect. 'table keeps the psqlrc.
;;
;; On SIGINT psql asks the server to cancel the running statement.

(require "../url.scm")
(require "../adapter.scm")

(provide postgres)

(define (build url mode)
  (require-authority url "postgres://user@host/database, or postgres:///database")
  (invocation (list "psql")
              (append (list "-w" "-v" "ON_ERROR_STOP=1")
                      (if (equal? mode 'plain) (list "-A" "-t" "-q" "-X") '())
                      (list "--dbname" (db-url-without-password url)))
              (password-env "PGPASSWORD" url)))

(define postgres (adapter "PostgreSQL" (list "postgres" "postgresql") build))
