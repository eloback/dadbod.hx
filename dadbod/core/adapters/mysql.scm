;; MySQL and MariaDB, through the `mysql` / `mariadb` client.
;;
;; MariaDB ships its client as `mariadb` and, on some systems only, also as
;; `mysql`; MySQL only has `mysql`. So each scheme prefers its own name and
;; falls back to the other.
;;
;;   --table                 ('table) the bordered output the client only
;;                           uses on a terminal
;;   --batch --skip-column-names   ('plain) tab-separated rows, no header
;;   --protocol tcp          with a port: for "localhost" the client would
;;                           otherwise ignore the port and use the default
;;                           unix socket
;;   --database=NAME         not a bare argument, so a name starting with "-"
;;                           can't be taken for an option
;;
;; Parameters after "?" become the client's options of the same name
;; (?ssl-ca=/etc/ca.pem is --ssl-ca=/etc/ca.pem), for the ones listed in
;; `options`. The two switches among them (`switches`) take "true", "false"
;; or nothing; the others need a value. A parameter that isn't listed is an
;; error. A unix socket is ?socket=/path, or the path percent-encoded where
;; the host goes (then without a port).
;;
;; On SIGINT the client kills the running statement on the server.

(require "../url.scm")
(require "../adapter.scm")

(provide mysql)

;; The parameters that are passed on. Both clients know most of them;
;; ssl-mode is MySQL's, ssl-verify-server-cert MariaDB's.
(define options
  (list "ssl"
        "ssl-ca"
        "ssl-capath"
        "ssl-cert"
        "ssl-cipher"
        "ssl-key"
        "ssl-mode"
        "ssl-verify-server-cert"
        "protocol"
        "socket"
        "default-character-set"
        "login-path"))

;; The options that are on or off. Every other one takes a value: without
;; it the client would take the next argument for the value.
(define switches (list "ssl" "ssl-verify-server-cert"))

(define (option-argument param)
  (define name (car param))
  (define value (cdr param))
  (unless (member name options)
    (error (string-append "'" name "' is not a parameter " "mysql URLs support (" (string-join options ", ") ")")))
  (cond
    [(member name switches)
     (cond
       [(or (equal? value "true") (equal? value "")) (string-append "--" name)]
       [(equal? value "false") (string-append "--skip-" name)]
       [else (error (string-append "the parameter '" name "' is true or false"))])]
    [(equal? value "") (error (string-append "the parameter '" name "' needs a value"))]
    [else (string-append "--" name "=" value)]))

(define (build url mode)
  (require-authority url "mysql://user@host/database")
  (define database (strip-leading-slash (db-url-path url)))
  (define params (db-url-params url))
  ;; The client only accepts --login-path as its very first option.
  (define (login-path? param)
    (equal? (car param) "login-path"))
  (define host (db-url-host url))
  (define socket-host? (and host (starts-with? host "/")))
  (when (and socket-host? (db-url-port url))
    (error "a mysql URL names a socket or a port, not both"))
  (invocation (if (equal? (db-url-scheme url) "mariadb")
                  (list "mariadb" "mysql")
                  (list "mysql" "mariadb"))
              (append (map option-argument (filter login-path? params))
                      (if (equal? mode 'plain) (list "--batch" "--skip-column-names") (list "--table"))
                      (cond
                        [socket-host? (list (string-append "--socket=" host))]
                        [host (list "--host" host)]
                        [else '()])
                      (if (db-url-port url)
                          (list "--port" (number->string (db-url-port url)) "--protocol" "tcp")
                          '())
                      (if (db-url-user url) (list "--user" (db-url-user url)) '())
                      (map option-argument (filter (lambda (p) (not (login-path? p))) params))
                      (if (string=? database "") '() (list (string-append "--database=" database))))
              (password-env "MYSQL_PWD" url)))

(define tables
  (string-append "select table_name from information_schema.tables"
                 " where table_schema = database() order by table_name;"))

(define helpers
  (list (cons "List" "select * from {table} limit 200;")
        (cons "Columns" "show columns from {table};")
        (cons "Indexes" "show indexes from {table};")
        (cons "Primary Key" "show indexes from {table} where key_name = 'PRIMARY';")
        (cons "Foreign Keys"
              (string-append
               "select constraint_name, column_name, referenced_table_name, referenced_column_name"
               " from information_schema.key_column_usage"
               " where table_schema = database() and table_name = '{name}'"
               " and referenced_table_name is not null;"))))

(define mysql (adapter "MySQL/MariaDB" (list "mysql" "mariadb") build tables helpers #f "`"))
