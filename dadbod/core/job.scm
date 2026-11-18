;; A database client as a child process: starting it, waiting for it, and
;; signalling it from elsewhere while it runs.
;;
;; stdin, stdout and stderr are all files, never pipes: nothing has to be
;; read while the client runs, so a large script or a large result can't
;; deadlock on a full pipe, and the caller only has to wait.
;;
;; Steel gives no process id for a child, and its `wait` holds the child
;; until it exits, so the client can't be killed through the handle. Instead
;; a one-line `sh` writes its own pid to a file and then becomes the client
;; (exec keeps the pid). Whoever knows the pid file can signal the client.
;;
;; run-client! blocks: call it off the main thread.
;;
;; No Helix.

(require "adapter.scm")
(require "system.scm")

(provide run-client!
         signal-client!)

(define (with-env builder env)
  (if (null? env)
      builder
      (with-env (with-env-var builder (car (car env)) (cdr (car env))) (cdr env))))

(define (quoted name)
  (string-append "'" name "'"))

;; The first of the invocation's candidate programs that is on PATH.
(define (find-program inv)
  (define candidates (invocation-programs inv))
  (define found (filter which candidates))
  (when (null? found)
    (error (if (null? (cdr candidates))
               (string-append (quoted (car candidates)) " is not on PATH")
               (string-append "none of "
                              (string-join (map quoted candidates) ", ")
                              " is on PATH"))))
  (car found))

;; $0 is the pid file, "$@" the client and its arguments.
(define become-client "echo \"$$\" > \"$0\" && exec \"$@\"")

;; Runs `inv` reading `stdin-file`, appending its stdout to `stdout-file` and
;; writing its stderr to `stderr-file`, and waits for it to exit. While it
;; runs, `pid-file` holds its process id (see signal-client!).
;;
;; Returns the exit code, or #f when the client was killed by a signal.
;; Raises an error with a message for the user when it can't be started.
(define (run-client! inv stdin-file stdout-file stderr-file pid-file)
  (define program (find-program inv))
  (unless (which "sh")
    (error "'sh' is not on PATH"))
  (define spawned
    (~> (command "sh" (append (list "-c" become-client pid-file program) (invocation-args inv)))
        (with-env (invocation-env inv))
        (with-stdin (open-input-file stdin-file))
        (with-stdout (open-output-file stdout-file #:exists 'append))
        (with-stderr (open-output-file stderr-file #:exists 'truncate))
        spawn-process))
  (when (Err? spawned)
    (error (string-append "could not start " (quoted program) ": " (to-string (Err->value spawned)))))
  (define status (wait (Ok->value spawned)))
  (when (Err? status)
    (error (string-append "could not wait for " (quoted program) ": " (to-string (Err->value status)))))
  (Ok->value status))

(define (digits? text)
  (and (> (string-length text) 0)
       (null? (filter (lambda (ch) (not (and (char>=? ch #\0) (char<=? ch #\9))))
                      (string->list text)))))

;; Sends `signal` ("INT", "TERM", "KILL") to the client whose pid is in
;; `pid-file`. Returns whether it was sent: #f when the client hasn't started
;; yet or is already gone.
;;
;; The caller must only signal a client it knows to be running: once the
;; client has exited, its pid can belong to another process.
(define (signal-client! pid-file signal)
  (define pid
    (with-handler (lambda (_) "") (trim (read-file pid-file))))
  (and (digits? pid)
       (with-handler (lambda (_) #f)
                     (let ([spawned (~> (command "kill" (list "-s" signal pid))
                                        with-stdout-piped
                                        ;; Not onto Helix's screen.
                                        with-stderr-piped
                                        spawn-process)])
                       (and (Ok? spawned)
                            (let ([status (wait (Ok->value spawned))])
                              (and (Ok? status) (equal? (Ok->value status) 0))))))))
