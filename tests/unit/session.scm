;; dadbod/core/session.scm

(require "steel/tests/unit-test.scm")
(require "lib.scm")
(require "../../dadbod/core/session.scm")

;; Starts runs of the given kinds, one second apart from t=1000: the session.
(define (session-with . kinds)
  (let loop ([s (new-session)] [kinds kinds] [now 1000])
    (if (null? kinds)
        s
        (loop (step-session (start-run s (car kinds) (string-append "sqlite:" (number->string now) ".db") now))
              (cdr kinds)
              (+ now 1000)))))

(define (running-ids s)
  (map run-id (session-running s)))

(define (after . steps)
  (step-session (car (reverse steps))))

;;; format-elapsed

(check-equal? "elapsed: milliseconds under a second, then seconds"
              (map format-elapsed (list 0 42 999 1000 3070 61234))
              (list "0ms" "42ms" "999ms" "1.00s" "3.07s" "61.23s"))

;;; Which database

;; A session where "sqlite:old.db" was used last and the buffer "a.sql" has
;; "prod" chosen for it.
(define chosen (use-for-buffer (remember-url (new-session) "sqlite:old.db") "a.sql" "prod"))

(check-equal? "url: the one given now wins, and its words are joined"
              (resolve-url chosen (list "sqlite:my" "file.db") "a.sql" "sqlite:env.db")
              "sqlite:my file.db")

(check-equal? "url: else the one chosen for the buffer"
              (resolve-url chosen '() "a.sql" "sqlite:env.db")
              "prod")

(check-equal? "url: else the one used last"
              (list (resolve-url chosen '() "b.sql" "sqlite:env.db") (resolve-url chosen '() #f "sqlite:env.db"))
              (list "sqlite:old.db" "sqlite:old.db"))

(check-equal? "url: else the environment's"
              (resolve-url (new-session) '() "a.sql" "sqlite:env.db")
              "sqlite:env.db")

(check-equal? "url: else an error"
              (error-message (lambda () (resolve-url (new-session) '() "a.sql" #f)))
              (string-append "no database: give a URL (:db-run postgres://user@host/db) or a "
                             "connection's name, or set $DATABASE_URL"))

(check-equal? "buffer: a choice is per buffer, and can be taken back"
              (list (buffer-url chosen "a.sql")
                    (buffer-url chosen "b.sql")
                    (buffer-url chosen #f)
                    (buffer-url (use-for-buffer chosen "a.sql" #f) "a.sql"))
              (list "prod" #f #f #f))

(check-equal? "last: the last run is remembered, through later runs"
              (let* ([s (remember-last (new-session) "prod" "select 1;")]
                     [started (start-run s 'show "sqlite:a.db" 0)]
                     [finished (finish-run (step-session started) 1 #f 10)])
                (list (session-last (new-session)) (session-last (step-session finished))))
              (list #f (cons "prod" "select 1;")))

;;; Starting and finishing

(check-equal? "start: runs get ids in order and the newest is first"
              (running-ids (session-with 'show 'show 'quiet))
              (list 3 2 1))

(check-equal? "start: a shown run is announced, without the password it never had"
              (step-effects (start-run (new-session) 'show "postgres://app@host/shop" 0))
              (list (list 'status "db-run: running on postgres://app@host/shop …")))

(check-equal? "start: a quiet run is not announced"
              (step-effects (start-run (new-session) 'quiet "postgres://app@host/shop" 0))
              '())

(check-equal? "start: the URL in use is kept"
              (session-url (after (start-run (remember-url (new-session) "sqlite:a.db") 'show "sqlite:a.db" 0)))
              "sqlite:a.db")

(check-equal? "finish: success shows the result and says how long it took"
              (step-effects (finish-run (session-with 'show) 1 #f 4070))
              (list (list 'show 1) (list 'result-status "db-run: done in 3.07s")))

(check-equal? "finish: a failure shows the result too, and is an error"
              (step-effects (finish-run (session-with 'show) 1 "the database client exited with code 1" 1042))
              (list (list 'show 1) (list 'error "db-run: the database client exited with code 1 (42ms)")))

(check-equal? "finish: a quiet run is delivered, with its failure, and nothing is shown"
              (list (step-effects (finish-run (session-with 'quiet) 1 #f 2000))
                    (step-effects (finish-run (session-with 'quiet) 1 "boom" 2000)))
              (list (list (list 'deliver 1 #f)) (list (list 'deliver 1 "boom"))))

(check-equal? "finish: the run is no longer running, the others are"
              (running-ids (after (finish-run (session-with 'show 'show 'show) 2 #f 9000)))
              (list 3 1))

(check-equal? "finish: runs can finish in any order"
              (let* ([s (session-with 'show 'show)]
                     [first (finish-run s 2 #f 5000)]
                     [second (finish-run (step-session first) 1 #f 6000)])
                (list (step-effects first) (step-effects second) (running-ids (step-session second))))
              (list (list (list 'show 2) (list 'result-status "db-run: done in 3.00s"))
                    (list (list 'show 1) (list 'result-status "db-run: done in 5.00s"))
                    '()))

(check-equal? "finish: a run that isn't running does nothing"
              (let ([s (session-with 'show)])
                (list (step-effects (finish-run s 99 #f 0)) (running-ids (after (finish-run s 99 #f 0)))))
              (list '() (list 1)))

;;; Cancelling

(check-equal? "cancel: with nothing running it is an error"
              (step-effects (cancel-run (new-session)))
              (list (list 'error "db-cancel: no query is running")))

(check-equal? "cancel: a quiet run is not the user's to cancel"
              (step-effects (cancel-run (session-with 'quiet)))
              (list (list 'error "db-cancel: no query is running")))

(check-equal? "cancel: first the database is asked, through the client"
              (step-effects (cancel-run (session-with 'show)))
              (list (list 'signal 1 "INT" "db-cancel: asked to cancel the query on sqlite:1000.db")))

(check-equal? "cancel: it hits the newest of the user's runs"
              (map cadr (step-effects (cancel-run (session-with 'show 'show 'quiet))))
              (list 2))

(define stop-note "; the server may still be running the query")

(check-equal? "cancel: asked again, it gets rougher each time"
              (let* ([one (cancel-run (session-with 'show))]
                     [two (cancel-run (step-session one))]
                     [three (cancel-run (step-session two))]
                     [four (cancel-run (step-session three))])
                (map (lambda (s) (cdr (car (step-effects s)))) (list two three four)))
              (list (list 1 "TERM" (string-append "db-cancel: stopped the client" stop-note))
                    (list 1 "KILL" (string-append "db-cancel: killed the client" stop-note))
                    (list 1 "KILL" (string-append "db-cancel: killed the client" stop-note))))

(check-equal? "cancel: escalation is per run"
              (let* ([one (cancel-run (session-with 'show))]
                     [started (start-run (step-session one) 'show "sqlite:new.db" 5000)]
                     [next (cancel-run (step-session started))])
                (cdr (car (step-effects next))))
              (list 2 "INT" "db-cancel: asked to cancel the query on sqlite:new.db"))

(check-equal? "cancel: a signal that couldn't be sent doesn't count"
              (let* ([one (cancel-run (session-with 'show))]
                     [undone (cancel-undelivered (step-session one) 1)]
                     [again (cancel-run (step-session undone))])
                (caddr (car (step-effects again))))
              "INT")

(check-equal? "cancel: undelivered for a run that is gone does nothing"
              (step-effects (cancel-undelivered (new-session) 7))
              '())

(check-equal? "cancel: a cancelled run that fails is 'cancelled', not an error"
              (let ([cancelled (cancel-run (session-with 'show))])
                (step-effects (finish-run (step-session cancelled) 1 "the database client exited with code 3" 3100)))
              (list (list 'show 1) (list 'result-status "db-run: cancelled after 2.10s")))

(check-equal? "cancel: a run that finished fine before the cancel landed is just done"
              (let ([cancelled (cancel-run (session-with 'show))])
                (step-effects (finish-run (step-session cancelled) 1 #f 3100)))
              (list (list 'show 1) (list 'result-status "db-run: done in 2.10s")))

(finish-tests!)
