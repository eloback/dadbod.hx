;; dadbod/core/connections.scm

(require "steel/tests/unit-test.scm")
(require "lib.scm")
(require "../../dadbod/core/connections.scm")

(define (described c)
  (list (connection-name c) (connection-reference c) (connection-source c)))

(define (parsed text)
  (define result (parse-connections text "file"))
  (list (map described (car result)) (cadr result)))

;;; Names

(check-equal? "name: what can be one"
              (map connection-name? (list "prod" "shop_dev-2.eu" "" "sqlite:a.db" "my db" "postgres://h/d" 7))
              (list #t #t #f #f #f #f #f))

;;; Files

(check-equal? "parse: names, references, comments and blank lines"
              (parsed (string-append "# my databases\n"
                                     "\n"
                                     "prod   !pass show databases/shop\n"
                                     "dev\tpostgres:///shop_dev\n"
                                     "  staging $STAGING_URL  \n"))
              (list (list (list "prod" "!pass show databases/shop" "file")
                          (list "dev" "postgres:///shop_dev" "file")
                          (list "staging" "$STAGING_URL" "file"))
                    '()))

(check-equal? "parse: an empty file has no connections" (parsed "") (list '() '()))

(check-equal? "parse: lines that can't be read are reported, the rest is kept"
              (parsed "good sqlite:a.db\nmy:name sqlite:b.db\nlonely\nalso-good sqlite:c.db\n")
              (list (list (list "good" "sqlite:a.db" "file") (list "also-good" "sqlite:c.db" "file"))
                    (list "file, line 2: a connection's name is letters, digits, _ . and -"
                          "file, line 3: 'lonely' has no URL after it")))

(check-equal? "format: a connection as a line parses back"
              (parsed (format-connection (connection "prod" "!pass show databases/shop" "x")))
              (list (list (list "prod" "!pass show databases/shop" "file")) '()))

;;; The environment

(check-equal? "environment: DB_UI_<NAME> is the connection <name>, lowercased"
              (map described
                   (environment-connections
                    (string-append "HOME=/home/me\n"
                                   "DB_UI_DEV=postgres:///shop_dev\n"
                                   "DB_UI_Staging_2=mysql://app@host/shop?ssl=true\n"
                                   "NOT_DB_UI_X=sqlite:x.db\n"
                                   "DB_UI_=sqlite:noname.db\n"
                                   "DB_UI_EMPTY=\n"
                                   "DB_UI_BAD-NAME!=sqlite:b.db\n")))
              (list (list "dev" "postgres:///shop_dev" "$DB_UI_DEV")
                    (list "staging_2" "mysql://app@host/shop?ssl=true" "$DB_UI_Staging_2")))

(check-equal? "environment: a variable can't hold a command"
              (environment-connections "DB_UI_EVIL=!touch /tmp/x; echo sqlite:a.db\n")
              '())

(check-equal? "environment: nothing there" (environment-connections "") '())

;;; Several sources

(define user (list (connection "prod" "sqlite:user-prod.db" "user") (connection "dev" "sqlite:user-dev.db" "user")))
(define project (list (connection "dev" "sqlite:project-dev.db" "project") (connection "test" "sqlite:t.db" "project")))

(check-equal? "merge: a later source replaces a name, in its first place"
              (map described (merge-connections (list user project)))
              (list (list "prod" "sqlite:user-prod.db" "user")
                    (list "dev" "sqlite:project-dev.db" "project")
                    (list "test" "sqlite:t.db" "project")))

(check-equal? "add-new: names already there are kept as they are, and reported"
              (let ([added (add-new-connections user project)])
                (list (map described (car added)) (cadr added)))
              (list (list (list "prod" "sqlite:user-prod.db" "user")
                          (list "dev" "sqlite:user-dev.db" "user")
                          (list "test" "sqlite:t.db" "project"))
                    (list "dev")))

(check-equal? "merge: nothing" (merge-connections (list '() '())) '())

(check-equal? "find: by name, or #f"
              (list (connection-reference (find-connection user "dev")) (find-connection user "nope"))
              (list "sqlite:user-dev.db" #f))

;;; References

(define (getenv name)
  (if (equal? name "SHOP_URL") " postgres://app:pw@host/shop \n" #f))

(define (run-command text)
  (cond
    [(equal? text "pass show shop") "postgres://app:pw@host/shop\nnotes: rotate in May\n"]
    [(equal? text "true") "\n"]
    [else (error "exited with code 1")]))

(define (resolved reference)
  (resolve-reference reference getenv run-command))

(check-equal? "reference: a URL is itself" (resolved "sqlite:a.db") "sqlite:a.db")

(check-equal? "reference: $VAR is the variable's value, trimmed"
              (resolved "$SHOP_URL")
              "postgres://app:pw@host/shop")

(check-equal? "reference: an unset variable is an error"
              (error-message (lambda () (resolved "$NOPE")))
              "the environment variable NOPE is not set")

(check-equal? "reference: !command is the first line it prints"
              (resolved "! pass show shop")
              "postgres://app:pw@host/shop")

(check-equal? "reference: a failing command is an error"
              (error-message (lambda () (resolved "!false")))
              "the command for the URL failed: exited with code 1")

(check-equal? "reference: a command that prints nothing is an error"
              (error-message (lambda () (resolved "!true")))
              "the command for the URL printed nothing")

(finish-tests!)
