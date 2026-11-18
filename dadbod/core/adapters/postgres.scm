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
  ;; The URL goes to psql whole, as an argument: a password in a parameter
  ;; would be there for `ps` to show.
  (unless (null? (filter (lambda (param) (member (string-downcase (car param)) (list "password" "sslpassword")))
                         (db-url-params url)))
    (error (string-append "give the password as postgres://user:password@…, not as a parameter: "
                          "there it would show in the process list")))
  (invocation (list "psql")
              (append (list "-w" "-v" "ON_ERROR_STOP=1")
                      (if (equal? mode 'plain) (list "-A" "-t" "-q" "-X") '())
                      (list "--dbname" (db-url-without-password url)))
              (password-env "PGPASSWORD" url)))

(define tables
  (string-append
   "select case when table_schema = 'public' then table_name"
   " else table_schema || '.' || table_name end"
   " from information_schema.tables"
   " where table_schema not in ('pg_catalog', 'information_schema')"
   " order by table_schema <> 'public', table_schema, table_name;"))

(define (constraints kind)
  (string-append "select conname as name, pg_get_constraintdef(oid) as definition"
                 " from pg_constraint"
                 " where contype = '"
                 kind
                 "' and conrelid = '{table-literal}'::regclass"
                 " order by conname;"))

(define helpers
  (list (cons "List" "select * from {table} limit 200;")
        (cons "Columns"
              (string-append
               "select column_name, data_type, is_nullable, column_default"
               " from information_schema.columns"
               " where table_schema = '{schema}' and table_name = '{name}'"
               " order by ordinal_position;"))
        (cons "Indexes"
              (string-append "select indexname, indexdef from pg_indexes"
                             " where schemaname = '{schema}' and tablename = '{name}';"))
        (cons "Primary Key" (constraints "p"))
        (cons "Foreign Keys" (constraints "f"))))

(define postgres
  (adapter "PostgreSQL" (list "postgres" "postgresql") build tables helpers "public" "\""))
