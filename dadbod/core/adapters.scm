;; The adapter registry: every database dadbod can talk to.
;;
;; Adding a database:
;;   1. write adapters/<name>.scm providing an `adapter` (see adapter.scm for
;;      what it is and the rules it follows);
;;   2. add it to `adapters` below;
;;   3. add its row to the fixtures in tests/unit/adapters.scm (the test
;;      fails until every registered adapter has one) and a part to
;;      tests/e2e/.
;;
;; No Helix.

(require "url.scm")
(require "adapter.scm")
(require "adapters/postgres.scm")
(require "adapters/mysql.scm")
(require "adapters/sqlite.scm")

(provide adapters
         supported-schemes
         adapter-for
         url->invocation)

(define adapters (list postgres mysql sqlite))

(define supported-schemes (apply append (map adapter-schemes adapters)))

;; The adapter for a parsed URL. Raises an error with a message for the user
;; when its scheme has none.
(define (adapter-for url)
  (define scheme (db-url-scheme url))
  (define found (filter (lambda (a) (member scheme (adapter-schemes a))) adapters))
  (when (null? found)
    (error (string-append "no adapter for '"
                          scheme
                          "' databases (supported: "
                          (string-join supported-schemes ", ")
                          ")")))
  (car found))

;; How to run a query against a parsed URL, with output for `mode` ('table
;; for a person, 'plain for a program). Raises an error with a message for
;; the user when the URL has no adapter or doesn't fit it.
(define (url->invocation url mode)
  ((adapter-build (adapter-for url)) url mode))
