;; dadbod/core/result.scm, with `sh` standing in for a database client.

(require "steel/tests/unit-test.scm")
(require "lib.scm")
(require "../../dadbod/core/adapter.scm")
(require "../../dadbod/core/result.scm")
(require "../../dadbod/core/system.scm")

(define scratch (make-scratch!))

(define (sh script)
  (invocation (list "sh") (list "-c" script) '()))

(define (left? name)
  (path-exists? (scratch name)))

(check-equal? "failure-of: what each outcome means"
              (map failure-of (list 0 3 #f "'psql' is not on PATH"))
              (list #f
                    "the database client exited with code 3"
                    "the database client was killed by a signal"
                    "'psql' is not on PATH"))

;;; run-to-result!

;; (failure result-text) and which of the query, stderr and pid files are left.
(define (result-of inv)
  (write-file! (scratch "query") "select 1;\n")
  (define failure
    (run-to-result! inv "sqlite:test.db" (scratch "query") (scratch "result") (scratch "stderr") (scratch "pid")))
  (list failure (read-file (scratch "result")) (map left? (list "query" "stderr" "pid"))))

(check-equal? "result: header, then stdout; only the result file is left"
              (result-of (sh "cat; echo '| 1 |'"))
              (list #f "-- sqlite:test.db\nselect 1;\n| 1 |\n" (list #f #f #f)))

(check-equal? "result: stdout, then stderr, then what went wrong"
              (result-of (sh "echo before; echo 'no such table' >&2; exit 1"))
              (list "the database client exited with code 1"
                    (string-append "-- sqlite:test.db\n"
                                   "before\n"
                                   "no such table\n"
                                   "-- db-run: the database client exited with code 1\n")
                    (list #f #f #f)))

(check-equal? "result: stderr without a final newline gets one"
              (cadr (result-of (sh "printf 'cut off' >&2; exit 2")))
              "-- sqlite:test.db\ncut off\n-- db-run: the database client exited with code 2\n")

(check-equal? "result: a client that can't be started is reported in the result"
              (result-of (invocation (list "no-such-database-client") '() '()))
              (list "'no-such-database-client' is not on PATH"
                    "-- sqlite:test.db\n-- db-run: 'no-such-database-client' is not on PATH\n"
                    (list #f #f #f)))

;; 0xE9 alone is "é" in Latin-1 and invalid in UTF-8: the bytes must come
;; through as they are, on stdout and on stderr.
(check-equal? "result: output that is not valid UTF-8 is kept byte for byte"
              (begin
                (write-file! (scratch "query") "")
                (run-to-result! (sh "printf 'caf\\351\\n'; printf 'err\\351\\n' >&2")
                                "x"
                                (scratch "query")
                                (scratch "result")
                                (scratch "stderr")
                                (scratch "pid"))
                (bytes->list (file-bytes (scratch "result"))))
              (append (bytes->list (string->bytes "-- x\ncaf"))
                      (list 233 10)
                      (bytes->list (string->bytes "err"))
                      (list 233 10)))

;;; run-to-files!

;; (failure stdout stderr) and which of the query and pid files are left.
(define (files-of inv)
  (write-file! (scratch "query") "select 1;\n")
  (define failure
    (run-to-files! inv (scratch "query") (scratch "stdout") (scratch "stderr") (scratch "pid")))
  (list failure
        (read-file (scratch "stdout"))
        (read-file (scratch "stderr"))
        (map left? (list "query" "pid"))))

(check-equal? "files: stdout and stderr exactly as written, nothing added"
              (files-of (sh "cat; echo warning >&2"))
              (list #f "select 1;\n" "warning\n" (list #f #f)))

(check-equal? "files: a failure leaves both files for the caller"
              (files-of (sh "echo partial; echo broke >&2; exit 4"))
              (list "the database client exited with code 4" "partial\n" "broke\n" (list #f #f)))

(check-equal? "files: output from an earlier run is not kept"
              (begin
                (files-of (sh "echo a long first line"))
                (cadr (files-of (sh "echo short"))))
              "short\n")

(check-equal? "files: a client that can't be started leaves two empty files"
              (files-of (invocation (list "no-such-database-client") '() '()))
              (list "'no-such-database-client' is not on PATH" "" "" (list #f #f)))

(scratch 'remove)
(finish-tests!)
