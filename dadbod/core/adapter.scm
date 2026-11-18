;; What an adapter is, and the helpers adapters share.
;;
;; An adapter knows one kind of database: which URL schemes are its own and
;; how to run a query against a URL with the database's command line client.
;; It builds an `invocation` (the client, its arguments, extra environment);
;; the query itself always goes to the client on stdin.
;;
;; The rules every adapter follows (tests/unit/adapters.scm checks them for
;; each registered adapter):
;;   - the password never goes into the arguments, where `ps` would show it:
;;     it is passed through the client's environment variable;
;;   - what the adapter doesn't understand (a query parameter, a URL without
;;     //) is an error, never dropped: silently ignoring `?ssl-mode=REQUIRED`
;;     would connect without the encryption that was asked for;
;;   - nothing taken from the URL can be read as an option by the client.
;;
;; No Helix.

(require "url.scm")

(provide adapter
         adapter?
         adapter-name
         adapter-schemes
         adapter-build
         invocation
         invocation?
         invocation-programs
         invocation-args
         invocation-env
         password-env
         require-authority
         refuse-query
         strip-leading-slash)

;; programs  client names to look up on PATH; the first one found is run
;; args      list of strings
;; env       list of (name . value) pairs added to the child's environment
(struct invocation (programs args env))

;; name     for messages, like "PostgreSQL"
;; schemes  the URL schemes it handles, lowercase
;; build    (url mode) -> invocation; raises an error with a message for the
;;          user when the URL doesn't fit. `mode` is how the output is
;;          meant to be read:
;;            'table  by a person: aligned, with headers
;;            'plain  by a program: one row per line, no headers or borders
(struct adapter (name schemes build))

(define (strip-leading-slash path)
  (if (starts-with? path "/")
      (substring path 1 (string-length path))
      path))

(define (password-env name url)
  (if (db-url-password url)
      (list (cons name (db-url-password url)))
      '()))

;; "postgres:app:secret@host/db" (the // forgotten) parses as a path, which
;; would put the password in the arguments and in the result's first line.
(define (require-authority url example)
  (unless (db-url-authority? url)
    (error (string-append (db-url-scheme url)
                          " URLs need the // after the scheme, like "
                          example))))

(define (refuse-query url)
  (when (db-url-query url)
    (error (string-append "query parameters (the part after '?') are not supported in "
                          (db-url-scheme url)
                          " URLs"))))
