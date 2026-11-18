;; Running an invocation (adapters.scm) as a child process.
;;
;; stdin, stdout and stderr are all files, never pipes: nothing has to be
;; read while the client runs, so a large script or a large result can't
;; deadlock on a full pipe, and the caller only has to wait.
;;
;; The client's output never passes through a Steel string, which has to be
;; valid UTF-8: stdout goes straight into the result file and stderr is
;; copied as bytes. A database can hold text in any encoding.
;;
;; Everything here blocks: call it off the main thread.
;;
;; Pure Steel, no Helix.

(require "adapters.scm")

(provide run-invocation
         run-to-result!
         failure-of
         read-file
         write-file!)

(define (read-file path)
  (define port (open-input-file path))
  (define text (read-port-to-string port))
  (close-input-port port)
  text)

(define (write-file! path text)
  (define port (open-output-file path #:exists 'truncate))
  (write-string text port)
  (close-output-port port))

(define (append-to-file! path write!)
  (define port (open-output-file path #:exists 'append))
  (write! port)
  (close-output-port port))

(define (delete-file-quietly! path)
  (with-handler (lambda (_) #f) (delete-file! path)))

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

;; Runs `inv` reading `stdin-file`, appending its stdout to `stdout-file` and
;; writing its stderr to `stderr-file`, and waits for it to exit.
;;
;; Returns the exit code, or #f when the client was killed by a signal.
;; Raises an error with a message for the user when it can't be started.
(define (run-invocation inv stdin-file stdout-file stderr-file)
  (define program (find-program inv))
  (define spawned
    (~> (command program (invocation-args inv))
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

;; What went wrong in a run, or #f. `outcome` is an exit code, #f for a
;; signal, or the message of the error that kept the client from running.
(define (failure-of outcome)
  (cond
    [(string? outcome) outcome]
    [(not outcome) "the database client was killed by a signal"]
    [(= outcome 0) #f]
    [else (string-append "the database client exited with code " (number->string outcome))]))

;; The bytes of a file, with a newline added if they don't end in one.
(define (file-bytes-with-newline path)
  (define port (open-input-file path))
  (define content (read-port-to-bytes port))
  (close-input-port port)
  (define len (bytes-length content))
  (if (or (= len 0) (= (bytes-ref content (- len 1)) 10))
      content
      (bytes-append content (bytes 10))))

;; A whole run, into `result-file`:
;;
;;   -- <header>
;;   <the client's stdout>
;;   <the client's stderr>
;;   -- db-run: <what went wrong>        only when something did
;;
;; `stdin-file` holds the query; it and `stderr-file` are deleted afterwards.
;; Returns what went wrong, or #f. Doesn't raise: a client that can't be
;; started is a failure like any other, reported in the result.
(define (run-to-result! inv header stdin-file result-file stderr-file)
  (define outcome
    (with-handler (lambda (err) (trim (error-object-message err)))
                  (begin
                    (write-file! result-file (string-append "-- " header "\n"))
                    (run-invocation inv stdin-file result-file stderr-file))))
  (define failure (failure-of outcome))
  (with-handler (lambda (_) #f)
                (append-to-file! result-file
                                 (lambda (port)
                                   (when (path-exists? stderr-file)
                                     (write-bytes (file-bytes-with-newline stderr-file) port))
                                   (when failure
                                     (write-string (string-append "-- db-run: " failure "\n") port)))))
  (delete-file-quietly! stdin-file)
  (delete-file-quietly! stderr-file)
  failure)
