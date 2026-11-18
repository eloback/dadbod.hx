;; dadbod.hx: run SQL from a Helix buffer against a database, in the spirit of
;; tpope/vim-dadbod.
;;
;;   (require "dadbod/dadbod.scm")      in init.scm
;;
;; This file is the plugin's entry point and nothing else: everything it
;; provides becomes a typed command in Helix, so it provides the commands and
;; only them. What they do is in dadbod/ (see docs/DESIGN.md); what other
;; plugins may use is dadbod/api.scm.

(require "dadbod/hx/commands.scm")

(provide db-run
         db-query
         db-rerun
         db-use
         db-cancel)


;;@doc
;; Run SQL against a database and show the result in a split.
;;
;; Runs the primary selection, or the whole buffer when nothing is selected.
;;
;; :db-run <database>  runs against it, and chooses it for this buffer
;; :db-run             runs against this buffer's database, else the one used
;;                     last, else $DATABASE_URL
;;
;; A database is a connection's name or a URL:
;;   postgres://user:password@host:port/database
;;   mysql://user:password@host:port/database   (also mariadb://)
;;   sqlite:relative/file.db   sqlite:///absolute/file.db
(define (db-run . args)
  (run-command! args)
  ;; Helix shows a typed command's return value in the status line, where it
  ;; would replace the command's own message.
  void)

;;@doc
;; Run the query typed after the command, against this buffer's database:
;; :db-query select count(*) from users
(define (db-query . words)
  (query-command! words)
  void)

;;@doc
;; Run the last query again, against the same database.
(define (db-rerun)
  (rerun-command!)
  void)

;;@doc
;; Choose the database of this buffer: :db-use <connection or URL>.
;; Without one, show which database is in use and the connections there are.
(define (db-use . args)
  (use-command! args)
  void)

;;@doc
;; Cancel the newest query that is still running.
;;
;; The first time it asks the database to cancel the statement. Run it again
;; for a query that doesn't stop: that stops the client, but the server may
;; go on running the statement.
(define (db-cancel)
  (cancel-command!)
  void)
