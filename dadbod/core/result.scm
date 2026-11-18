;; A whole run of a query, start to finish, into files.
;;
;; The client's output never passes through a Steel string, which has to be
;; valid UTF-8: stdout goes straight into its file and stderr is copied as
;; bytes. A database can hold text in any encoding.
;;
;; Both functions block until the client exits (call them off the main
;; thread), delete the files that were only needed while it ran, and don't
;; raise: a client that can't be started is a failure like any other.
;;
;; No Helix.

(require "adapter.scm")
(require "job.scm")
(require "system.scm")

(provide run-to-result!
         run-to-files!
         failure-of)

;; What went wrong in a run, or #f. `outcome` is an exit code, #f for a
;; signal, or the message of the error that kept the client from running.
(define (failure-of outcome)
  (cond
    [(string? outcome) outcome]
    [(not outcome) "the database client was killed by a signal"]
    [(= outcome 0) #f]
    [else (string-append "the database client exited with code " (number->string outcome))]))

(define (outcome-of thunk)
  (with-handler (lambda (err) (trim (error-object-message err))) (thunk)))

;; The bytes of a file, with a newline added if they don't end in one.
(define (file-bytes-with-newline path)
  (define content (file-bytes path))
  (define len (bytes-length content))
  (if (or (= len 0) (= (bytes-ref content (- len 1)) 10))
      content
      (bytes-append content (bytes 10))))

;; For a person to read: everything in `result-file`.
;;
;;   -- <header>
;;   <the client's stdout>
;;   <the client's stderr>
;;   -- db-run: <what went wrong>        only when something did
;;
;; `stdin-file` holds the query. It, `stderr-file` and `pid-file` are deleted
;; afterwards. Returns what went wrong, or #f.
(define (run-to-result! inv header stdin-file result-file stderr-file pid-file)
  (define failure
    (failure-of (outcome-of (lambda ()
                              (write-file! result-file (string-append "-- " header "\n"))
                              (run-client! inv stdin-file result-file stderr-file pid-file)))))
  (with-handler (lambda (_) #f)
                (append-to-file! result-file
                                 (lambda (port)
                                   (when (path-exists? stderr-file)
                                     (write-bytes (file-bytes-with-newline stderr-file) port))
                                   (when failure
                                     (write-string (string-append "-- db-run: " failure "\n") port)))))
  (for-each delete-file-quietly! (list stdin-file stderr-file pid-file))
  failure)

;; For a program to read: stdout in `stdout-file` and stderr in
;; `stderr-file`, exactly as the client wrote them, both left for the caller.
;;
;; `stdin-file` and `pid-file` are deleted afterwards. Returns what went
;; wrong, or #f.
(define (run-to-files! inv stdin-file stdout-file stderr-file pid-file)
  (define failure
    (failure-of (outcome-of (lambda ()
                              (write-file! stdout-file "")
                              (write-file! stderr-file "")
                              (run-client! inv stdin-file stdout-file stderr-file pid-file)))))
  (for-each delete-file-quietly! (list stdin-file pid-file))
  failure)
