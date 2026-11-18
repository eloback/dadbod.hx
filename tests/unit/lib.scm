;; Shared by the unit test files. Each of those is run on its own:
;;
;;   steel tests/unit/url.scm        (tests/unit.sh runs them all)
;;
;; and ends with (finish-tests!), which fails the process when a check failed.

(require "steel/tests/unit-test.scm")
(require "../../dadbod/core/system.scm")

(provide error-message
         make-scratch!
         finish-tests!)

;; The message of the error `thunk` raises, or #f. Steel puts a space in front
;; of an error's message, so it is trimmed, as the plugin does to show it.
(define (error-message thunk)
  (with-handler (lambda (err) (trim (error-object-message err)))
                (begin
                  (thunk)
                  #f)))

;; A fresh directory for a test file's temporary files. Returns a function:
;;   (scratch "name")    the path of a file in it
;;   (scratch 'remove)   delete the directory and everything in it
(define (make-scratch!)
  (define dir (make-private-dir! (list (getenv "TMPDIR") "/tmp") "dadbod-unit"))
  (lambda (what)
    (cond
      [(string? what) (string-append dir "/" what)]
      [else
       (for-each (lambda (entry) (delete-file-quietly! entry)) (read-dir dir))
       (delete-directory! dir)])))

(define (finish-tests!)
  (define stats (get-test-stats))
  (displayln "passed: " (hash-ref stats 'success-count) ", failed: " (hash-ref stats 'failure-count))
  (unless (zero? (hash-ref stats 'failure-count))
    (error "unit tests failed")))
