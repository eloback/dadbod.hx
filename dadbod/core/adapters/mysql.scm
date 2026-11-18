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
;; On SIGINT the client kills the running statement on the server.

(require "../url.scm")
(require "../adapter.scm")

(provide mysql)

(define (build url mode)
  (require-authority url "mysql://user@host/database")
  (refuse-query url)
  (define database (strip-leading-slash (db-url-path url)))
  (invocation (if (equal? (db-url-scheme url) "mariadb")
                  (list "mariadb" "mysql")
                  (list "mysql" "mariadb"))
              (append (if (equal? mode 'plain) (list "--batch" "--skip-column-names") (list "--table"))
                      (if (db-url-host url) (list "--host" (db-url-host url)) '())
                      (if (db-url-port url)
                          (list "--port" (number->string (db-url-port url)) "--protocol" "tcp")
                          '())
                      (if (db-url-user url) (list "--user" (db-url-user url)) '())
                      (if (string=? database "") '() (list (string-append "--database=" database))))
              (password-env "MYSQL_PWD" url)))

(define mysql (adapter "MySQL/MariaDB" (list "mysql" "mariadb") build))
