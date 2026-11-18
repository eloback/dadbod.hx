;; dadbod/core/job.scm, with `sh` standing in for a database client.

(require "steel/tests/unit-test.scm")
(require "lib.scm")
(require "../../dadbod/core/adapter.scm")
(require "../../dadbod/core/job.scm")
(require "../../dadbod/core/system.scm")
(require-builtin steel/time)

(define scratch (make-scratch!))

(define (sh script env)
  (invocation (list "sh") (list "-c" script) env))

(define (run! inv)
  (run-client! inv (scratch "stdin") (scratch "stdout") (scratch "stderr") (scratch "pid")))

;; Runs `script` with `stdin` as its input: (exit-code stdout stderr).
(define (run-sh script stdin env)
  (write-file! (scratch "stdin") stdin)
  (delete-file-quietly! (scratch "stdout"))
  (define code (run! (sh script env)))
  (list code (read-file (scratch "stdout")) (read-file (scratch "stderr"))))

(check-equal? "run: stdin, stdout, stderr and the exit code"
              (run-sh "cat; echo problem >&2; exit 3" "select 1;\n" '())
              (list 3 "select 1;\n" "problem\n"))

(check-equal? "run: success is exit code 0" (run-sh "true" "" '()) (list 0 "" ""))

(check-equal? "run: the arguments reach the client as they are"
              (begin
                (write-file! (scratch "stdin") "")
                (delete-file-quietly! (scratch "stdout"))
                (run! (invocation (list "printf") (list "%s|" "a b" "$HOME" "it's" "--x=1") '()))
                (read-file (scratch "stdout")))
              "a b|$HOME|it's|--x=1|")

(check-equal? "run: the environment reaches the client"
              (run-sh "printf %s \"$DADBOD_TEST_PASSWORD\"" "" (list (cons "DADBOD_TEST_PASSWORD" "p@ss word")))
              (list 0 "p@ss word" ""))

(check-equal? "run: a client killed by a signal has no exit code"
              (car (run-sh "kill -9 $$" "" '()))
              #f)

(check-equal? "run: stdout is appended to what the file holds"
              (begin
                (write-file! (scratch "stdin") "")
                (write-file! (scratch "stdout") "-- header\n")
                (run! (sh "echo row" '()))
                (read-file (scratch "stdout")))
              "-- header\nrow\n")

(check-equal? "run: the first client on PATH is the one that runs"
              (begin
                (write-file! (scratch "stdin") "")
                (delete-file-quietly! (scratch "stdout"))
                (run! (invocation (list "no-such-database-client" "sh") (list "-c" "echo second") '()))
                (read-file (scratch "stdout")))
              "second\n")

(check-equal? "run: a missing client is an error"
              (error-message (lambda () (run! (invocation (list "no-such-database-client") '() '()))))
              "'no-such-database-client' is not on PATH")

(check-equal? "run: all candidates missing is an error naming them"
              (error-message (lambda () (run! (invocation (list "no-such-client-a" "no-such-client-b") '() '()))))
              "none of 'no-such-client-a', 'no-such-client-b' is on PATH")

;;; The pid file and signals

;; The pid file holds the client's own pid: the client prints its pid, and
;; the two must agree.
(check-equal? "pid: the pid file holds the client's pid"
              (begin
                (write-file! (scratch "stdin") "")
                (delete-file-quietly! (scratch "stdout"))
                (run! (sh "echo $$" '()))
                (equal? (trim (read-file (scratch "stdout"))) (trim (read-file (scratch "pid")))))
              #t)

(check-equal? "signal: no pid file yet means nothing is sent"
              (begin
                (delete-file-quietly! (scratch "pid"))
                (signal-client! (scratch "pid") "INT"))
              #f)

(check-equal? "signal: a pid file that isn't a pid means nothing is sent"
              (begin
                (write-file! (scratch "pid") "-1\n")
                (signal-client! (scratch "pid") "INT"))
              #f)

;; A client that would run for a minute, signalled from this thread while
;; another one waits for it: (sent? exit-code stdout).
(define (signal-running script signal)
  (write-file! (scratch "stdin") "")
  (delete-file-quietly! (scratch "stdout"))
  (delete-file-quietly! (scratch "pid"))
  (define waiter (spawn-native-thread (lambda () (run! (sh script '())))))
  ;; Until the client is up: its pid is written and its first line is out.
  (let loop ([tries 0])
    (unless (or (> tries 200)
                (and (path-exists? (scratch "pid"))
                     (path-exists? (scratch "stdout"))
                     (string-contains? (read-file (scratch "stdout")) "ready")))
      (time/sleep-ms 20)
      (loop (+ tries 1))))
  (define sent (signal-client! (scratch "pid") signal))
  (define code (thread-join! waiter))
  (list sent code (read-file (scratch "stdout"))))

(check-equal? "signal: INT reaches the running client, which can clean up and report"
              (signal-running "trap 'echo interrupted; exit 7' INT; echo ready; sleep 60 & wait" "INT")
              (list #t 7 "ready\ninterrupted\n"))

(check-equal? "signal: TERM stops a client that doesn't handle it"
              (signal-running "echo ready; sleep 60 & wait" "TERM")
              (list #t #f "ready\n"))

(scratch 'remove)
(finish-tests!)
