;; What a Helix session's dadbod knows, and what each thing that happens does
;; to it: which database is in use, which queries are running, what to tell
;; the user.
;;
;; Everything here is pure. A function takes the session and what happened,
;; and returns a `step`: the session afterwards, plus the effects to carry
;; out, as data. hx/commands.scm holds the one current session and carries
;; the effects out. So the rules (which run a cancel hits, how it escalates,
;; what the status line says) are tested without Helix or a database.
;;
;; Effects, each a list:
;;   (status <text>)               show in the status line
;;   (error <text>)                show in the status line, as an error
;;   (result-status <text>)        like status, about the run whose result the
;;                                 `show` just before it is for
;;   (show <run id>)               make that run's result the result shown
;;   (deliver <run id> <failure>)  hand a quiet run's output to its callback
;;   (signal <run id> <signal> <text>)
;;                                 signal the run's client; <text> is the
;;                                 status once it has been sent
;;
;; No Helix.

(provide new-session
         session?
         session-url
         session-running
         session-last
         resolve-url
         remember-url
         use-for-buffer
         buffer-url
         remember-last
         start-run
         finish-run
         cancel-run
         cancel-undelivered
         step?
         step-session
         step-effects
         step-run
         run?
         run-id
         run-kind
         run-display
         run-started
         run-cancels
         format-elapsed)

;; A "database", here, is what the user typed to say which one: a URL or
;; the name of a connection. What it stands for is looked up at each run.
;;
;; url      the database used last, or #f
;; next-id  the id the next run gets
;; running  the runs in progress, newest first
;; buffers  buffer key -> the database chosen for that buffer
;; last     (database . sql) of the last run shown, for a rerun, or #f
(struct session (url next-id running buffers last))

;; kind     'show: a run of the user's, its result is shown
;;          'quiet: a run for another plugin, its output goes to a callback
;; display  the database's URL without its password
;; started  milliseconds
;; cancels  how many times the user asked to cancel it
(struct run (id kind display started cancels))

;; run: the run the step is about, or #f
(struct step (session effects run))

(define (new-session)
  (session #f 1 '() (hash) #f))

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

;;; Which database

;; The database to run against: the one given now (`args`, the words after
;; the command), else the one chosen for the buffer (`buffer-key`, or #f for
;; no buffer), else the one used last, else `env-url` ($DATABASE_URL or #f).
(define (resolve-url s args buffer-key env-url)
  (cond
    [(not (null? args)) (string-join args " ")]
    [(buffer-url s buffer-key) (buffer-url s buffer-key)]
    [(session-url s) (session-url s)]
    [env-url env-url]
    [else
     (error (string-append "no database: give a URL (:db-run postgres://user@host/db) or a "
                           "connection's name, or set $DATABASE_URL"))]))

(define (remember-url s text)
  (session text (session-next-id s) (session-running s) (session-buffers s) (session-last s)))

;; The database chosen for a buffer, or #f.
(define (buffer-url s key)
  (and key (hash-try-get (session-buffers s) key)))

;; Chooses `text` for the buffer `key`; #f for `text` un-chooses.
(define (use-for-buffer s key text)
  (session (session-url s)
           (session-next-id s)
           (session-running s)
           (if text (hash-insert (session-buffers s) key text) (hash-remove (session-buffers s) key))
           (session-last s)))

(define (remember-last s text sql)
  (session (session-url s) (session-next-id s) (session-running s) (session-buffers s) (cons text sql)))

;;; Runs

(define (find-run s id)
  (define found (filter (lambda (r) (equal? (run-id r) id)) (session-running s)))
  (and (not (null? found)) (car found)))

(define (without-run s id)
  (session (session-url s)
           (session-next-id s)
           (filter (lambda (r) (not (equal? (run-id r) id))) (session-running s))
           (session-buffers s)
           (session-last s)))

(define (replace-run s new)
  (session (session-url s)
           (session-next-id s)
           (map (lambda (r) (if (equal? (run-id r) (run-id new)) new r)) (session-running s))
           (session-buffers s)
           (session-last s)))

(define (with-cancels r cancels)
  (run (run-id r) (run-kind r) (run-display r) (run-started r) cancels))

;; A run begins. The step's run carries its id.
(define (start-run s kind display now)
  (define new (run (session-next-id s) kind display now 0))
  (step (session (session-url s)
                 (+ (session-next-id s) 1)
                 (cons new (session-running s))
                 (session-buffers s)
                 (session-last s))
        (if (equal? kind 'show)
            (list (list 'status (string-append "db-run: running on " display " …")))
            '())
        new))

;; A run's client has exited; `failure` is what went wrong, or #f.
(define (finish-run s id failure now)
  (define r (find-run s id))
  (cond
    [(not r) (step s '() #f)]
    [(equal? (run-kind r) 'quiet) (step (without-run s id) (list (list 'deliver id failure)) r)]
    [else
     (let ([elapsed (format-elapsed (- now (run-started r)))])
       (step (without-run s id)
             (list (list 'show id)
                   (cond
                     [(not failure) (list 'result-status (string-append "db-run: done in " elapsed))]
                     ;; It failed because it was asked to: not an error.
                     [(> (run-cancels r) 0)
                      (list 'result-status (string-append "db-run: cancelled after " elapsed))]
                     [else (list 'error (string-append "db-run: " failure " (" elapsed ")"))]))
             r))]))

;; The user asks to cancel. It hits the newest shown run still going (the
;; user's own, or one another plugin started with dadbod-run!), and gets
;; rougher each time it is asked again for the same run:
;;   1. INT: the client asks the server to cancel the statement, and exits;
;;   2. TERM: the client is stopped; the server isn't told;
;;   3. KILL.
(define (cancel-run s)
  (define shown (filter (lambda (r) (equal? (run-kind r) 'show)) (session-running s)))
  (cond
    [(null? shown) (step s (list (list 'error "db-cancel: no query is running")) #f)]
    [else
     (let* ([r (with-cancels (car shown) (+ (run-cancels (car shown)) 1))]
            [n (run-cancels r)]
            [left-running "; the server may still be running the query"])
       (step (replace-run s r)
             (list (cond
                     [(= n 1)
                      (list 'signal
                            (run-id r)
                            "INT"
                            (string-append "db-cancel: asked to cancel the query on " (run-display r)))]
                     [(= n 2)
                      (list 'signal
                            (run-id r)
                            "TERM"
                            (string-append "db-cancel: stopped the client" left-running))]
                     [else
                      (list 'signal
                            (run-id r)
                            "KILL"
                            (string-append "db-cancel: killed the client" left-running))]))
             r))]))

;; The signal of a cancel couldn't be sent (the client hadn't started yet):
;; that cancel doesn't count, so the next one starts over with INT.
(define (cancel-undelivered s id)
  (define r (find-run s id))
  (if (and r (> (run-cancels r) 0))
      (step (replace-run s (with-cancels r (- (run-cancels r) 1))) '() r)
      (step s '() r)))
