;; SQLite, through sqlite3.
;;
;; sqlite:notes.db (relative to Helix's working directory) or
;; sqlite:///home/me/notes.db (absolute).
;;   -bail              stop at the first failing statement
;;   -table             ('table) bordered output with headers
;;   -list -noheader    ('plain) rows with | between the columns
;;
;; On SIGINT sqlite3 interrupts the running statement.

(require "../url.scm")
(require "../adapter.scm")

(provide sqlite)

(define (build url mode)
  (when (db-url-host url)
    (error (string-append "sqlite URLs have no host: use sqlite:relative/path.db or "
                          "sqlite:///absolute/path.db")))
  (refuse-query url)
  (define path (db-url-path url))
  (when (string=? path "")
    (error "sqlite URL has no file: use sqlite:relative/path.db or sqlite:///absolute/path.db"))
  (invocation (list "sqlite3")
              (append (list "-bail")
                      (if (equal? mode 'plain) (list "-list" "-noheader") (list "-table"))
                      ;; "./-notes.db": a file name starting with "-" is not an option.
                      (list (if (starts-with? path "-") (string-append "./" path) path)))
              '()))

(define sqlite (adapter "SQLite" (list "sqlite" "sqlite3") build))
