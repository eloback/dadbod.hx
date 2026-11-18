;; What the commands do. This file holds the session's state and carries out
;; the effects core/session.scm decides on; the editor is reached only
;; through editor.scm.
;;
;; How a run goes:
;;   1. on the main thread: resolve the URL, write the query to a file;
;;   2. on a worker thread: run the database client into files of this run's
;;      own and wait for it, so neither a slow query nor a large result
;;      freezes the editor;
;;   3. back on the main thread: for the user's own run, make its file the
;;      result file and show it; for another plugin's, call it back.
;;
;; All state here is only touched on the main thread.

(require "editor.scm")
(require "../core/url.scm")
(require "../core/adapters.scm")
(require "../core/result.scm")
(require "../core/job.scm")
(require "../core/session.scm")
(require "../core/system.scm")

(provide run-command!
         cancel-command!
         run-sql!
         query-sql!
         current-url
         use-url!)

;;; State

(define *session* (new-session))
;; This Helix session's private directory for query and result files.
(define *session-dir* #f)
;; The document showing the result file, once it has been opened, and the
;; file it shows.
(define *result-doc* #f)
(define *result-path* #f)
;; The result file waiting for normal mode to be shown, or #f.
(define *show-pending* #f)
;; run id -> the directory its files are in. A run keeps the directory it
;; started in, even if the session has moved to a new one since.
(define *run-dirs* (hash))
;; run id -> the callback of a quiet run.
(define *callbacks* (hash))

;; Takes a step: the session becomes the step's, and its effects are carried
;; out. One effect failing doesn't keep the others from happening.
(define (advance! s)
  (set! *session* (step-session s))
  (for-each (lambda (effect)
              (with-handler (lambda (err)
                              (error-status! (string-append "dadbod: "
                                                            (trim (error-object-message err)))))
                            (carry-out! effect)))
            (step-effects s))
  s)

;;; Files

;; Queries and results can be sensitive: they go to a directory only the
;; user can read, under XDG_RUNTIME_DIR (emptied at logout) when there is
;; one. Made on the first run, and again if it has gone since: a runtime
;; directory doesn't outlive the login session, a long-lived Helix can.
(define (session-dir!)
  (unless (and *session-dir* (is-dir? *session-dir*))
    (set! *session-dir*
          (make-private-dir! (list (getenv "XDG_RUNTIME_DIR") (getenv "TMPDIR") "/tmp") "dadbod-hx")))
  *session-dir*)

(define (run-file dir id name)
  (string-append dir "/" name "-" (number->string id)))

;; The directory a run's files are in.
(define (run-dir id)
  (or (hash-try-get *run-dirs* id) (session-dir!)))

(define (forget-run! id)
  (set! *run-dirs* (hash-remove *run-dirs* id))
  (set! *callbacks* (hash-remove *callbacks* id)))

;; Whether the focused buffer is a file in the session directory. By path,
;; not by document: the result file can be opened by hand too. Both sides are
;; resolved first, since either may have been reached through a symlink.
(define (in-result-buffer?)
  (define (resolved path)
    (with-handler (lambda (_) path) (canonicalize-path path)))
  (define path (focused-path))
  (and path
       *session-dir*
       (starts-with? (resolved path) (string-append (resolved *session-dir*) "/"))))

;;; Effects

;; Shows the result file that is waiting, if one still is.
(define (show-pending!)
  (when *show-pending*
    (let ([path *show-pending*])
      (set! *show-pending* #f)
      ;; The window of the last result is only reused for the same file.
      (set! *result-doc* (show-in-split! path (and (equal? path *result-path*) *result-doc*)))
      (set! *result-path* path))))

(define (show-result! id)
  (define dir (run-dir id))
  (define path (string-append dir "/result.dbout"))
  (forget-run! id)
  (rename-file-or-directory! (run-file dir id "result") path)
  ;; A result already waiting for normal mode is replaced by this one.
  (let ([waiting *show-pending*])
    (set! *show-pending* path)
    (unless waiting
      (run-when-normal! show-pending!))))

(define (deliver! id failure)
  (define dir (run-dir id))
  (define stdout-file (run-file dir id "stdout"))
  (define stderr-file (run-file dir id "stderr"))
  (define callback (hash-try-get *callbacks* id))
  (forget-run! id)
  (when callback
    (with-handler (lambda (err)
                    (error-status! (string-append "dadbod: a query callback failed: "
                                                  (trim (error-object-message err)))))
                  (callback failure stdout-file stderr-file)))
  (delete-file-quietly! stdout-file)
  (delete-file-quietly! stderr-file))

(define (running? id)
  (member id (map run-id (session-running *session*))))

;; Signals a run's client. A cancel can come before the client has written
;; its pid (the run was only just started), so a signal that can't be sent
;; is tried again for a second, as long as the run is still going.
(define (signal! id signal sent-text tries)
  (cond
    [(signal-client! (run-file (run-dir id) id "pid") signal) (status! sent-text)]
    ;; It finished by itself in the meantime: nothing left to cancel.
    [(not (running? id)) #f]
    [(< tries 10) (run-later! 100 (lambda () (signal! id signal sent-text (+ tries 1))))]
    [else
     (advance! (cancel-undelivered *session* id))
     (error-status! "db-cancel: could not reach the database client")]))

(define (carry-out! effect)
  (define kind (car effect))
  (cond
    [(equal? kind 'status) (status! (cadr effect))]
    ;; The status of a run whose result was just handed to show-result!.
    [(equal? kind 'result-status)
     (status! (if *show-pending*
                  (string-append (cadr effect) ", shown when back in normal mode")
                  (cadr effect)))]
    [(equal? kind 'error) (error-status! (cadr effect))]
    [(equal? kind 'show) (show-result! (cadr effect))]
    [(equal? kind 'deliver) (deliver! (cadr effect) (caddr effect))]
    [(equal? kind 'signal) (signal! (cadr effect) (caddr effect) (cadddr effect) 0)]
    [else (error-status! "dadbod: unknown effect")]))

;;; Runs

;; Starts `sql` against the URL `url-text`. `kind` is 'show or 'quiet (see
;; core/session.scm); a quiet run's `callback` gets
;; (failure stdout-file stderr-file) on the main thread when it is done.
;; Raises an error with a message for the user when it can't be started.
(define (start! kind url-text sql callback)
  (define url (parse-url url-text))
  (define invocation (url->invocation url (if (equal? kind 'show) 'table 'plain)))
  (when (string=? (trim sql) "")
    (error "nothing to run: the query is blank"))
  (define dir (session-dir!))
  (define display (db-url-display url))
  (define started (advance! (start-run *session* kind display (now-ms))))
  (define id (run-id (step-run started)))
  (define (file name)
    (run-file dir id name))
  (set! *run-dirs* (hash-insert *run-dirs* id dir))
  (when callback
    (set! *callbacks* (hash-insert *callbacks* id callback)))
  ;; From here on the session counts the run as running. If it can't be
  ;; started after all, it must not stay that way: nothing would ever finish
  ;; it, and :db-cancel would keep aiming at it.
  (with-handler (lambda (err)
                  (set! *session* (step-session (finish-run *session* id #f (now-ms))))
                  (forget-run! id)
                  (error (trim (error-object-message err))))
                (begin
                  (write-file! (file "query") sql)
                  (spawn-worker
                   (lambda ()
                     (define failure
                       (if (equal? kind 'show)
                           (run-to-result! invocation
                                           display
                                           (file "query")
                                           (file "result")
                                           (file "stderr")
                                           (file "pid"))
                           (run-to-files! invocation (file "query") (file "stdout") (file "stderr") (file "pid"))))
                     (on-main-thread (lambda () (advance! (finish-run *session* id failure (now-ms)))))))))
  ;; Not the thread: a caller that is a typed command would have Helix print
  ;; it in the status line.
  void)

;;; For the commands (dadbod.scm)

;; The primary selection. A selection of at most one character, or of
;; nothing but whitespace (the cursor on an empty line), is just the cursor,
;; and stands for the whole buffer.
(define (query-text)
  (define selected (selection-text))
  (if (or (<= (string-length selected) 1) (string=? (trim selected) ""))
      (buffer-text)
      selected))

(define (reporting-errors command thunk)
  (with-handler (lambda (err)
                  (error-status! (string-append command ": " (trim (error-object-message err)))))
                (thunk)))

;; :db-run. `args` are the words after the command: a URL, or nothing.
(define (run-command! args)
  (reporting-errors
   "db-run"
   (lambda ()
     (when (in-result-buffer?)
       (error "this is the result buffer: run it from the buffer with the query"))
     (define text (resolve-url *session* args (getenv "DATABASE_URL")))
     (start! 'show text (query-text) #f)
     ;; Remembered only now that it parsed, has an adapter and started.
     (set! *session* (remember-url *session* text)))))

;; :db-cancel
(define (cancel-command!)
  (reporting-errors "db-cancel" (lambda () (advance! (cancel-run *session*)))))

;;; For other plugins (api.scm)

;; The URL :db-run would use now, as text, or #f.
(define (current-url)
  (with-handler (lambda (_) #f) (resolve-url *session* '() (getenv "DATABASE_URL"))))

;; Makes `url-text` the URL later runs use. Raises an error with a message
;; for the user when it isn't a URL dadbod can run against.
(define (use-url! url-text)
  (url->invocation (parse-url url-text) 'table)
  (set! *session* (remember-url *session* url-text)))

;; Runs `sql` against `url-text` and shows the result, as :db-run does.
(define (run-sql! url-text sql)
  (start! 'show url-text sql #f))

;; Runs `sql` against `url-text` without showing anything; see start!.
(define (query-sql! url-text sql callback)
  (start! 'quiet url-text sql callback))
