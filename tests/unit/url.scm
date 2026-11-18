;; dadbod/core/url.scm

(require "steel/tests/unit-test.scm")
(require "lib.scm")
(require "../../dadbod/core/url.scm")

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

(define (params text)
  (db-url-params (parse-url text)))

(check-equal? "params: pairs in order, decoded; none without a query"
              (list (params "mysql://h/d?ssl-ca=%2Fetc%2Fca.pem&ssl=true&flag&x=a%3Db") (params "mysql://h/d"))
              (list (list (cons "ssl-ca" "/etc/ca.pem") (cons "ssl" "true") (cons "flag" "") (cons "x" "a=b"))
                    '()))

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

(finish-tests!)
