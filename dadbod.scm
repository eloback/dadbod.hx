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
         db-cancel)

;;@doc
;; Run SQL against a database and show the result in a split.
;;
;; Runs the primary selection, or the whole buffer when nothing is selected.
;;
;; :db-run <url>  runs against <url> and remembers it for this session
;; :db-run        runs against the remembered URL, else $DATABASE_URL
;;
;; URLs: postgres://user:password@host:port/database
;;       mysql://user:password@host:port/database   (also mariadb://)
;;       sqlite:relative/file.db   sqlite:///absolute/file.db
(define (db-run . args)
  (run-command! args)
  ;; Helix shows a typed command's return value in the status line, where it
  ;; would replace the command's own message.
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
