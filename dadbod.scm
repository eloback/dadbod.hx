;; dadbod.hx: run SQL from a Helix buffer against a database, in the spirit of
;; tpope/vim-dadbod.
;;
;;   (require "dadbod/dadbod.scm")      in init.scm, then  :db-run [url]
;;
;; This file is the Helix side. The pieces that don't need Helix are in
;; url.scm (parsing), adapters.scm (which client to run) and run.scm (running
;; it), and are unit-tested on their own.
;;
;; How a run goes:
;;   1. on the main thread: resolve the URL, take the query from the buffer,
;;      write it to a file;
;;   2. on a native thread: run the database client into a result file of
;;      this run's own and wait for it, so neither a slow query nor a large
;;      result freezes the editor;
;;   3. back on the main thread: make that file the result file and show it
;;      in a split.

(require "helix/editor.scm")
(require "helix/misc.scm")
(require "helix/static.scm")
(require "helix/ext.scm")
(require (prefix-in helix. "helix/commands.scm"))
(require-builtin helix/core/text as text.)
(require-builtin steel/time)

(require "url.scm")
(require "adapters.scm")
(require "run.scm")

(provide db-run)

;;; State. Only ever touched on the main thread.

;; The URL last given to :db-run, as typed. Reused by later runs.
(define *url* #f)
;; This Helix session's private directory for query and result files.
(define *session-dir* #f)
;; Number of runs started, to name each run's files.
(define *runs* 0)
;; The document showing the result file, once it has been opened.
(define *result-doc* #f)
;; Whether a result is waiting for normal mode to be shown.
(define *show-pending* #f)

;;; Files

(define (getenv name)
  (with-handler (lambda (_) #f)
                (let ([value (env-var name)])
                  (and (> (string-length value) 0) value))))

;; Where the session directory goes: XDG_RUNTIME_DIR, which only the user can
;; read and which is emptied at logout, else the temporary directory.
(define (session-base)
  (define candidates (list (getenv "XDG_RUNTIME_DIR") (getenv "TMPDIR") "/tmp"))
  (define usable (filter (lambda (dir) (and dir (is-dir? dir))) candidates))
  (when (null? usable)
    (error "no directory for the query and result files: set XDG_RUNTIME_DIR or TMPDIR"))
  (trim-end-matches (car usable) "/"))

;; Queries and results can be sensitive, so the directory is made by
;; `mktemp -d`: created in one step, readable by the user only, under a name
;; nobody could have put a link at beforehand.
(define (make-session-dir!)
  (define template (string-append (session-base) "/dadbod-hx.XXXXXX"))
  (define made
    (with-handler (lambda (_) #f)
                  (let ([spawned (~> (command "mktemp" (list "-d" template))
                                     with-stdout-piped
                                     spawn-process)])
                    (and (Ok? spawned)
                         (let ([out (wait->stdout (Ok->value spawned))])
                           (and (Ok? out) (trim (Ok->value out))))))))
  (unless (and made (is-dir? made))
    (error "could not make a private directory for the query and result files (mktemp -d failed)"))
  made)

;; Made on the first run, and again if it has gone since (a runtime directory
;; doesn't outlive the login session, a Helix inside tmux can).
(define (session-dir!)
  (unless (and *session-dir* (is-dir? *session-dir*))
    (set! *session-dir* (make-session-dir!)))
  *session-dir*)

(define (result-file)
  (string-append (session-dir!) "/result.dbout"))

;;; The query

(define (focused-doc)
  (editor->doc-id (editor-focus)))

;; The primary selection. In Helix the cursor is itself a selection, one
;; character wide, so a selection of at most one character, or of nothing but
;; whitespace (the cursor on an empty line), stands for the whole buffer.
(define (query-text)
  (define selected (current-highlighted-text!))
  (if (or (<= (string-length selected) 1) (string=? (trim selected) ""))
      (text.rope->string (editor->text (focused-doc)))
      selected))

;; The URL to run against: the one given now (remembered for later runs),
;; else the one given before, else $DATABASE_URL.
(define (url-text args)
  (cond
    [(not (null? args)) (string-join args " ")]
    [*url* *url*]
    [(getenv "DATABASE_URL") (getenv "DATABASE_URL")]
    [else (error "no database: give a URL (:db-run postgres://user@host/db) or set $DATABASE_URL")]))

;;; The result

;; "42ms" under a second, "3.07s" from there on.
(define (format-elapsed ms)
  (define hundredths (quotient (remainder ms 1000) 10))
  (if (< ms 1000)
      (string-append (number->string ms) "ms")
      (string-append (number->string (quotient ms 1000))
                     "."
                     (if (< hundredths 10) "0" "")
                     (number->string hundredths)
                     "s")))

(define (normal-mode?)
  (equal? (editor-mode) (string->editor-mode "normal")))

;; Shows the result file in a horizontal split, reusing the split when it is
;; still open, and leaves the focus where it was.
;;
;; Moving the focus puts Helix in normal mode, so this must only run in
;; normal mode: see show-when-normal!.
(define (show-result! path)
  (define origin (editor-focus))
  (define view
    (and *result-doc* (editor-doc-exists? *result-doc*) (editor-doc-in-view? *result-doc*)))
  (with-handler (lambda (err)
                  (set-error! (string-append "db-run: could not show the result: "
                                             (trim (error-object-message err)))))
                (begin
                  (if view
                      (editor-set-focus! view)
                      (begin
                        (helix.hsplit path)
                        (set! *result-doc* (focused-doc))))
                  ;; The file changed under a buffer that may hold the last result.
                  (editor-document-reload *result-doc*)
                  (helix.goto-line 1)))
  (editor-set-focus! origin))

;; Shows the result now in normal mode, and otherwise once Helix is back in
;; it: showing it while the user types would end insert mode under their
;; fingers, and the keys that follow would run as commands.
(define (show-when-normal! path)
  (cond
    [(normal-mode?)
     (set! *show-pending* #f)
     (show-result! path)]
    [else
     (set! *show-pending* #t)
     (enqueue-thread-local-callback-with-delay 150 (lambda () (show-when-normal! path)))]))

;; `run-result` is the finished run's own result file, `failure` what went
;; wrong in it or #f.
(define (finish-run! run-result failure started)
  (define elapsed (format-elapsed (- (current-milliseconds) started)))
  (define path (result-file))
  (rename-file-or-directory! run-result path)
  ;; A result already waiting for normal mode will show this one: same file.
  (unless *show-pending*
    (show-when-normal! path))
  (cond
    [failure (set-error! (string-append "db-run: " failure " (" elapsed ")"))]
    [*show-pending*
     (set-status! (string-append "db-run: done in " elapsed ", shown when back in normal mode"))]
    [else (set-status! (string-append "db-run: done in " elapsed))]))

;;; The run

(define (start-run! url invocation query)
  (define dir (session-dir!))
  (set! *runs* (+ *runs* 1))
  (define (file name)
    (string-append dir "/" name "-" (number->string *runs*)))
  (define query-file (string-append (file "query") ".sql"))
  (define stderr-file (file "stderr"))
  (define run-result (file "result"))
  (define display (db-url-display url))
  (define started (current-milliseconds))
  (write-file! query-file query)
  (set-status! (string-append "db-run: running on " display " …"))
  (spawn-native-thread
   (lambda ()
     (define failure (run-to-result! invocation display query-file run-result stderr-file))
     (hx.with-context (lambda () (finish-run! run-result failure started))))))

;; Whether the focused buffer is a file in the session directory. By path,
;; not by document: the result file can be opened by hand too. Both sides are
;; resolved first, since either may have been reached through a symlink.
(define (in-result-buffer?)
  (define (resolved path)
    (with-handler (lambda (_) path) (canonicalize-path path)))
  (define path (editor-document->path (focused-doc)))
  (and (string? path)
       *session-dir*
       (starts-with? (resolved path) (string-append (resolved *session-dir*) "/"))))

(define (run! args)
  (when (in-result-buffer?)
    (error "this is the result buffer: run it from the buffer with the query"))
  (define text (url-text args))
  (define url (parse-url text))
  (define invocation (url->invocation url))
  (define query (query-text))
  (when (string=? (trim query) "")
    (error "nothing to run: the buffer is blank"))
  ;; Remembered only now that it parsed and has an adapter.
  (set! *url* text)
  (start-run! url invocation query))

;;@doc
;; Run SQL against a database and show the result in a split.
;;
;; Runs the primary selection, or the whole buffer when nothing is selected.
;;
;; :db-run <url>  runs against <url> and remembers it for this session
;; :db-run        runs against the remembered URL, else $DATABASE_URL
;;
;; URLs: postgres://user:password@host:port/database
;;       mysql://user:password@host:port/database   (also mariadb://)
;;       sqlite:relative/file.db   sqlite:///absolute/file.db
(define (db-run . args)
  (with-handler (lambda (err)
                  (set-error! (string-append "db-run: " (trim (error-object-message err)))))
                (run! args))
  ;; Helix shows a typed command's return value in the status line, where it
  ;; would replace the "running" message.
  void)
