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
(require "../core/adapter.scm")
(require "../core/adapters.scm")
(require "../core/connections.scm")
(require "../core/result.scm")
(require "../core/job.scm")
(require "../core/session.scm")
(require "../core/system.scm")

(provide run-command!
         query-command!
         rerun-command!
         use-command!
         cancel-command!
         bind-result-keys!
         run-sql!
         query-sql!
         cancel-id!
         current-url
         adapter-of
         database-of-path
         database-of-file!
         use-url!
         use-for-path!
         all-connections
         connection-problems
         register-connections!
         save-connection!
         database-display
         not-a-query!
         listen!)

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
;; Connections given from init.scm.
(define *registered* '())
;; Connections from the environment, once it has been looked at; #f before.
(define *from-environment* #f)
;; Functions other plugins asked to be told events through.
(define *listeners* '())
;; database, as typed -> its adapter, once it has been looked up.
(define *adapters* (hash))
;; Functions other plugins gave to say which database a file belongs to:
;; each takes a path and returns a database or #f.
(define *databases-of-files* '())
;; Functions other plugins gave to say "the focused buffer is not a query":
;; each returns why not, as text, or #f.
(define *not-a-query* '())

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
      ;; Now, not when the plugin was loaded: the keys are a copy of the
      ;; global ones, and init.scm may have added to those since.
      (bind-result-keys!)
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
      (run-when-not-typing! show-pending!))))

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
                  (string-append (cadr effect) ", shown when you leave insert mode")
                  (cadr effect)))]
    [(equal? kind 'error) (error-status! (cadr effect))]
    [(equal? kind 'show) (show-result! (cadr effect))]
    [(equal? kind 'deliver) (deliver! (cadr effect) (caddr effect))]
    [(equal? kind 'signal) (signal! (cadr effect) (caddr effect) (cadddr effect) 0)]
    [else (error-status! "dadbod: unknown effect")]))

;;; Which database

(define (config-home)
  (or (getenv "XDG_CONFIG_HOME") (string-append (or (getenv "HOME") "") "/.config")))

;; The connections file every project shares, and the project's own.
(define (user-connections-file)
  (string-append (config-home) "/helix/dadbod-connections"))

(define (project-connections-file)
  (string-append (workspace-dir) "/.helix/dadbod-connections"))

;; (list connections problems) from one file; nothing from a missing one.
;; Only a regular file of a sane size: a project's file comes with its
;; repository, and a link to a pipe or to /dev/zero in its place would hang
;; Helix or fill its memory.
(define (read-connections path)
  (cond
    [(not (path-exists? path)) (list '() '())]
    [(not (and (is-file? path)
               (with-handler (lambda (_) #f) (<= (fs-metadata-len (file-metadata path)) 65536))))
     (list '() (list (string-append path ": not read (not a plain file, or larger than 64 KiB)")))]
    [else
     (with-handler (lambda (_) (list '() (list (string-append path ": could not be read"))))
                   (parse-connections (read-file path) path))]))

;; The connections the environment defines (DB_UI_<NAME>). Asked once: the
;; environment of a running Helix doesn't change, and asking runs `env`.
(define (from-environment)
  (unless *from-environment*
    (set! *from-environment*
          (with-handler
           (lambda (_) '())
           ;; `env` prints lines, and a variable's value can have lines of
           ;; its own that look like more variables: only those that really
           ;; are variables, with that value, count.
           (filter (lambda (c)
                     (define variable (substring (connection-source c) 1 (string-length (connection-source c))))
                     (equal? (trim (or (getenv variable) "")) (connection-reference c)))
                   (environment-connections (command-output "env"))))))
  *from-environment*)

;; The user's own connections. A name defined twice is the later one's: the
;; user's file, init.scm, the environment.
(define (own-connections)
  (merge-connections (list (car (read-connections (user-connections-file)))
                           *registered*
                           (from-environment))))

;; (list connections refused): every connection there is, and the names the
;; project's file defines that are the user's already. The project's file
;; can add connections but not replace one: it comes with the repository,
;; and `prod` must not quietly become someone else's server. The files are
;; read anew each time: they are small and may have just been edited.
(define (with-project)
  (add-new-connections (own-connections) (car (read-connections (project-connections-file)))))

(define (all-connections)
  (car (with-project)))

(define (project-connection? c)
  (equal? (connection-source c) (project-connections-file)))

;; The lines of the connections files that couldn't be read, each as a
;; message. The user's file is named in short: its path fills a status line.
(define (connection-problems)
  (define (problems-of path short)
    (map (lambda (problem) (string-replace problem path short)) (cadr (read-connections path))))
  (append (problems-of (user-connections-file) "your dadbod-connections")
          (problems-of (project-connections-file) ".helix/dadbod-connections")
          (map (lambda (name)
                 (string-append ".helix/dadbod-connections: '"
                                name
                                "' is one of your own connections already; the project's is ignored"))
               (cadr (with-project)))))

;; What a database, as typed, stands for right now: (list name url-text),
;; the name #f for a URL. Looks the URL up, which may run the command of a
;; connection: so this is only for when the user asked for this database
;; (running against it, :db-use <database>), never for showing or listing.
;; Raises an error with a message for the user.
;;
;; A connection from the project's file can't use a command: the file comes
;; with the repository, and naming a connection must not run what a
;; stranger wrote.
(define (look-up database)
  (cond
    [(connection-name? database)
     (let ([found (find-connection (all-connections) database)])
       (unless found
         (error (string-append "no connection called '" database "'")))
       (when (and (starts-with? (connection-reference found) "!") (project-connection? found))
         (error (string-append "the connection '"
                               database
                               "' in .helix/dadbod-connections gets its URL from a command: "
                               "that is only allowed in your own connections file")))
       ;; A connection the repository brought is shown as such, wherever
       ;; its name is shown with its URL.
       (list (if (project-connection? found) (string-append database " [project]") database)
             (resolve-reference (connection-reference found) getenv command-output)))]
    [else (list #f database)]))

;; The adapter of a database, without looking a connection up again once it
;; has been: the kind of database behind a name doesn't change.
(define (adapter-of database)
  (or (hash-try-get *adapters* database)
      (let ([found (adapter-for (parse-url (cadr (look-up database))))])
        (set! *adapters* (hash-insert *adapters* database found))
        found)))

;; A URL as it is shown: never with its password. A URL its adapter refuses
;; is shown as its scheme only: one written without the // parses with the
;; password in its path.
(define (shown-url url)
  (if (with-handler (lambda (_) #f)
                    (begin
                      (url->invocation url 'table)
                      #t))
      (db-url-display url)
      (string-append (db-url-scheme url) ":…")))

;; How a database that was looked up is shown.
(define (display-of name url)
  (if name
      (string-append name " (" (shown-url url) ")")
      (shown-url url)))

;; How a database is shown without looking it up: a connection by its name.
(define (shown-as-typed database)
  (if (connection-name? database)
      database
      (with-handler (lambda (_) "a database that is not a URL") (shown-url (parse-url database)))))

;;; Runs

(define (notify! event)
  (for-each (lambda (listener)
              (with-handler (lambda (_) #f) (listener event)))
            *listeners*))

;; Starts `sql` against `database` (a URL or a connection's name). `kind` is
;; 'show or 'quiet (see core/session.scm); a quiet run's `callback` gets
;; (failure stdout-file stderr-file) on the main thread when it is done.
;; Returns the run's id. Raises an error with a message for the user when it
;; can't be started.
(define (start! kind database sql callback)
  (when (string=? (trim sql) "")
    (error "nothing to run: the query is blank"))
  (define looked-up (look-up database))
  (define url (parse-url (cadr looked-up)))
  (define invocation (url->invocation url (if (equal? kind 'show) 'table 'plain)))
  (set! *adapters* (hash-insert *adapters* database (adapter-for url)))
  (define dir (session-dir!))
  (define display (display-of (car looked-up) url))
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
  (define problem
    (with-handler (lambda (err) (trim (error-object-message err)))
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
                       (on-main-thread (lambda ()
                                         (advance! (finish-run *session* id failure (now-ms)))
                                         (notify! (list 'run-finished id failure))))))
                    #f)))
  ;; An error can't be raised from inside a handler (it crashes Steel), so
  ;; the handler hands the message out and it is raised here.
  (when problem
    (set! *session* (step-session (finish-run *session* id #f (now-ms))))
    (forget-run! id)
    (error problem))
  (when (equal? kind 'show)
    (set! *session* (remember-last *session* database sql)))
  id)

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

;; The database a plugin says the file at `path` belongs to, or #f.
(define (database-of-file path)
  (let loop ([askers *databases-of-files*])
    (if (or (not path) (null? askers))
        #f
        (or (with-handler (lambda (_) #f) ((car askers) path)) (loop (cdr askers))))))

;; The database of the buffer `key` (a path), with nothing given: the one
;; chosen for it, else the one a plugin says its file belongs to, else the
;; one used last, else $DATABASE_URL.
(define (database-for key path args)
  (cond
    [(not (null? args)) (resolve-url *session* args key #f)]
    [(buffer-url *session* key) (buffer-url *session* key)]
    [(database-of-file path) (database-of-file path)]
    [else (resolve-url *session* '() key (getenv "DATABASE_URL"))]))

(define (current-database args)
  (database-for (buffer-key) (focused-path) args))

;; `database` becomes the one used last, and the focused buffer's.
(define (chosen! database)
  (set! *session* (use-for-buffer (remember-url *session* database) (buffer-key) database))
  (notify! (list 'database-changed)))

;; :db-run. `args` are the words after the command: a database, or nothing.
(define (run-command! args)
  (reporting-errors
   "db-run"
   (lambda ()
     (when (in-result-buffer?)
       (error "this is the result buffer: run it from the buffer with the query (R reruns the last one)"))
     (for-each (lambda (why-not)
                 (define reason (why-not))
                 (when reason
                   (error reason)))
               *not-a-query*)
     (define database (current-database args))
     (start! 'show database (query-text) #f)
     ;; Chosen only now that it was found, has an adapter and started.
     (chosen! database))))

;; :db-query. `words` are the query.
(define (query-command! words)
  (reporting-errors
   "db-query"
   (lambda ()
     (when (null? words)
       (error "give the query: :db-query select count(*) from users"))
     (start! 'show (current-database '()) (string-join words " ") #f))))

;; :db-rerun
(define (rerun-command!)
  (reporting-errors
   "db-rerun"
   (lambda ()
     (define last (session-last *session*))
     (unless last
       (error "no query has run yet"))
     (start! 'show (car last) (cdr last) #f))))

;; :db-use. With a database: chooses it for the focused buffer, after
;; checking that it can be run against. Without: says which one is in use.
(define (use-command! args)
  (reporting-errors
   "db-use"
   (lambda ()
     (cond
       [(null? args)
        (let* ([database (with-handler (lambda (_) #f) (current-database '()))]
               [names (map connection-name (all-connections))]
               [problems (connection-problems)])
          (status! (string-append "db-use: "
                                  (if database (shown-as-typed database) "no database chosen")
                                  (if (null? names)
                                      ""
                                      (string-append "  |  connections: " (string-join names ", ")))
                                  (if (null? problems)
                                      ""
                                      (string-append "  |  " (car problems))))))]
       [else
        (let* ([database (string-join args " ")]
               [found (look-up database)]
               [url (parse-url (cadr found))])
          (url->invocation url 'table)
          (chosen! database)
          (status! (string-append "db-use: " (display-of (car found) url))))]))))

;; :db-cancel
(define (cancel-command!)
  (reporting-errors "db-cancel" (lambda () (advance! (cancel-run *session*)))))

;; The keys of a result buffer (any .dbout file): rerun, cancel, close.
(define (bind-result-keys!)
  (set-extension-keys! "dbout" (hash "R" ":db-rerun" "C-c" ":db-cancel" "q" ":quit")))

;;; For other plugins (api.scm)

;; The database :db-run would use in the focused buffer now, as typed (a URL
;; or a connection's name), or #f.
(define (current-url)
  (with-handler (lambda (_) #f) (current-database '())))

;; Checks what can be checked about `database` without looking it up: a
;; name has to be a connection's, a URL has to have an adapter. Raises an
;; error with a message for the user otherwise.
(define (check-shape database)
  (if (connection-name? database)
      (unless (find-connection (all-connections) database)
        (error (string-append "no connection called '" database "'")))
      (adapter-for (parse-url database))))

;; Makes `database` the one later runs use, in the focused buffer and after.
;; Looks it up, to check that it can be run against.
(define (use-url! database)
  (adapter-of database)
  (chosen! database))

;; Chooses `database` for the buffer with the key `key` (a file's path)
;; only, whether it is open or not. Doesn't look it up.
(define (use-for-path! path database)
  (check-shape database)
  (set! *session* (use-for-buffer *session* path database)))

;; The database :db-run would use in the file at `path`, as typed, or #f.
(define (database-of-path path)
  (with-handler (lambda (_) #f) (database-for path path '())))

;; `asker` is asked which database a file belongs to, when none was chosen
;; for its buffer: it takes the file's path and returns a database, or #f.
(define (database-of-file! asker)
  (set! *databases-of-files* (cons asker *databases-of-files*)))

;; Runs `sql` against `database` and shows the result, as :db-run does.
(define (run-sql! database sql)
  (start! 'show database sql #f))

;; Runs `sql` against `database` without showing anything; see start!.
(define (query-sql! database sql callback)
  (start! 'quiet database sql callback))

;; Asks the client of the run `id` to cancel, whoever started it. Returns
;; whether the signal was sent.
(define (cancel-id! id)
  (and (running? id) (signal-client! (run-file (run-dir id) id "pid") "INT")))

;; Adds connections given from init.scm: `pairs` is a list of
;; (name . reference).
(define (register-connections! pairs)
  (set! *registered*
        (merge-connections
         (list *registered*
               (map (lambda (pair) (connection (car pair) (cdr pair) "init.scm")) pairs))))
  (notify! (list 'connections-changed)))

;; Adds a connection to the user's connections file.
(define (save-connection! name reference)
  (unless (connection-name? name)
    (error "a connection's name is letters, digits, _ . and -"))
  (when (string=? (trim reference) "")
    (error "a connection needs a URL"))
  ;; The file is plain text and stays around: no password in it. A URL is
  ;; only saved when it reads as one and its adapter takes it: one that
  ;; doesn't can have a password where it isn't looked for.
  (unless (or (starts-with? (trim reference) "$") (starts-with? (trim reference) "!"))
    (let ([verdict (with-handler (lambda (err) (trim (error-object-message err)))
                                 (let ([url (parse-url reference)])
                                   (url->invocation url 'table)
                                   (if (db-url-password url) 'password 'fine)))])
      (cond
        [(equal? verdict 'password)
         (error (string-append "that URL has a password in it, which would be saved as it is: give "
                               "$VARIABLE or !command instead (see the README), or the URL without it"))]
        [(string? verdict) (error (string-append "not saved: " verdict))])))
  (when (find-connection (car (read-connections (user-connections-file))) name)
    (error (string-append "there is a connection called '" name "' already")))
  (define path (user-connections-file))
  (unless (is-dir? (parent-name path))
    (create-directory! (parent-name path)))
  ;; On a line of its own, also after a last line without a newline.
  (define before (if (path-exists? path) (read-file path) ""))
  (append-to-file! path
                   (lambda (port)
                     (write-string (string-append (if (or (string=? before "") (ends-with? before "\n")) "" "\n")
                                                  (format-connection (connection name (trim reference) path))
                                                  "\n")
                                   port)))
  (notify! (list 'connections-changed)))

;; `listener` is called with each event, a list:
;;   (database-changed)            another database is in use
;;   (connections-changed)         a connection was added
;;   (run-finished id failure)     a run ended
(define (listen! listener)
  (set! *listeners* (cons listener *listeners*)))

;; `database` as it is shown: a connection's name, or a URL without its
;; password. Doesn't look anything up.
(define (database-display database)
  (shown-as-typed database))

;; `why-not` is asked before :db-run runs the focused buffer: it returns
;; text when the buffer is not a query (it is a plugin's own panel, say),
;; and that text is the error; #f otherwise.
(define (not-a-query! why-not)
  (set! *not-a-query* (cons why-not *not-a-query*)))
