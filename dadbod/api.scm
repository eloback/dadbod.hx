;; dadbod's API for other plugins: the one file of dadbod another plugin
;; requires, dadbod-ui first of all (tests/lint.sh checks that it requires
;; nothing else of dadbod).
;;
;;   (require "dadbod/dadbod/api.scm")       from init.scm or an installed plugin
;;   (require "../dadbod/api.scm")           from dadbod-ui/, in this repository
;;
;; Both name the same file, so both get the same dadbod: the URL chosen in
;; one plugin is the one the other runs against.
;;
;; Everything here is called on the main thread and raises an error with a
;; message for the user when it can't do what was asked.

(require "core/url.scm")
(require "core/adapters.scm")
(require "hx/commands.scm")

(provide dadbod-current-url
         dadbod-use-url!
         dadbod-url-display
         dadbod-supported-schemes
         dadbod-run!
         dadbod-query!)

;; The URL :db-run would run against now, as text, or #f: the one used last,
;; else $DATABASE_URL. It can hold a password: show it only through
;; dadbod-url-display.
(define (dadbod-current-url)
  (current-url))

;; Makes `url-text` the URL :db-run and dadbod-current-url use from now on.
(define (dadbod-use-url! url-text)
  (use-url! url-text))

;; `url-text` without its password and its parameters: the form that is safe
;; to show.
(define (dadbod-url-display url-text)
  (db-url-display (parse-url url-text)))

;; The URL schemes there is an adapter for, like "postgres" and "sqlite".
(define (dadbod-supported-schemes)
  supported-schemes)

;; Runs `sql` against `url-text` and shows the result in the result split,
;; exactly as :db-run does for a buffer.
(define (dadbod-run! url-text sql)
  (run-sql! url-text sql))

;; Runs `sql` against `url-text` without showing anything, for a plugin that
;; wants to read the answer itself (a list of tables, say).
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
(define (dadbod-query! url-text sql callback)
  (query-sql! url-text sql callback))
