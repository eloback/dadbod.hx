;; Files, the environment and the clock: the few things core/ needs from the
;; operating system, in one place.
;;
;; No Helix (see docs/DESIGN.md, "core/ and hx/").

(require-builtin steel/time)

(provide getenv
         now-ms
         read-file
         write-file!
         append-to-file!
         delete-file-quietly!
         file-bytes
         make-private-dir!)

;; The variable's value, or #f when it is unset or empty.
(define (getenv name)
  (with-handler (lambda (_) #f)
                (let ([value (env-var name)])
                  (and (> (string-length value) 0) value))))

(define (now-ms)
  (current-milliseconds))

;; Text files only: Steel strings are UTF-8. For anything a database client
;; wrote, use file-bytes.
(define (read-file path)
  (define port (open-input-file path))
  (define text (read-port-to-string port))
  (close-input-port port)
  text)

(define (write-file! path text)
  (define port (open-output-file path #:exists 'truncate))
  (write-string text port)
  (close-output-port port))

;; Calls `write!` with a port that appends to the file.
(define (append-to-file! path write!)
  (define port (open-output-file path #:exists 'append))
  (write! port)
  (close-output-port port))

(define (delete-file-quietly! path)
  (with-handler (lambda (_) #f) (delete-file! path)))

(define (file-bytes path)
  (define port (open-input-file path))
  (define content (read-port-to-bytes port))
  (close-input-port port)
  content)

;; Makes a directory only the user can read, named `prefix` plus random
;; characters, in the first of `bases` that is a directory (#f entries are
;; skipped). Returns its path; raises when it can't.
;;
;; It is made by `mktemp -d`: created in one step with mode 700, under a name
;; nobody could have put a link at beforehand.
(define (make-private-dir! bases prefix)
  (define usable (filter (lambda (dir) (and dir (is-dir? dir))) bases))
  (when (null? usable)
    (error "no directory to keep files in: set XDG_RUNTIME_DIR or TMPDIR"))
  (define template
    (string-append (trim-end-matches (car usable) "/") "/" prefix ".XXXXXX"))
  (define made
    (with-handler (lambda (_) #f)
                  (let ([spawned (~> (command "mktemp" (list "-d" template))
                                     with-stdout-piped
                                     ;; Not onto Helix's screen.
                                     with-stderr-piped
                                     spawn-process)])
                    (and (Ok? spawned)
                         (let ([out (wait->stdout (Ok->value spawned))])
                           (and (Ok? out) (trim (Ok->value out))))))))
  (unless (and made (is-dir? made))
    (error "could not make a private directory for the query and result files (mktemp -d failed)"))
  made)
