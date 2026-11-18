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
         adapter-tables
         adapter-helpers
         adapter-default-schema
         adapter-mark
         expand-helper
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
;;
;; For a plugin that browses the database (dadbod-ui):
;;
;; tables   SQL that lists the tables and views, one name per row: bare for
;;          the default schema, schema.table for the others
;; helpers  ready-made queries about one table, as (name . template) pairs
;;          in the order to offer them; see expand-helper
;; default-schema
;;          the schema a bare table name is in, or #f when the database has
;;          none to name
;; mark     the character identifiers are quoted with: " or `
(struct adapter (name schemes build tables helpers default-schema mark))

(define (doubling text ch)
  (string-replace text ch (string-append ch ch)))

;; A helper's SQL for a table. The table's name comes from the database and
;; can be anything, so it never goes into the SQL as it is. In the template,
;;   {table}          is the table as an identifier, quoted, with its schema
;;                    where the database has schemas: "public"."books"
;;   {table-literal}  the same, for inside a string: 'x'::regclass
;;   {schema}         its schema, for inside a string: the default one for a
;;                    bare name, "" where there are none
;;   {name}           its name without the schema, for inside a string
;; A name is only split at a dot where the database has schemas: elsewhere a
;; dot is part of the name.
;;
;; A name with a backslash, a brace or a control character in it is refused.
;; Quoting those right depends on the server's settings and on how each
;; client reads its input (psql and mysql take backslashes for their own
;; commands), and getting it wrong runs what a hostile database put in a
;; table's name.
(define (expand-helper template table default-schema mark)
  (unless (null? (filter (lambda (ch)
                           (or (member ch (list #\\ #\{ #\}))
                               (< (char->integer ch) 32)
                               (= (char->integer ch) 127)))
                         (string->list table)))
    (error (string-append "this table's name has a backslash, a brace or a control character in "
                          "it: the helpers don't run on such names")))
  (define parts (split-many table "."))
  (define qualified? (and default-schema (not (null? (cdr parts))) (null? (cddr parts))))
  (define schema (if qualified? (car parts) (or default-schema "")))
  (define name (if qualified? (cadr parts) table))
  (define (identifier text)
    (string-append mark (doubling text mark) mark))
  (define (in-string text)
    (doubling text "'"))
  (define quoted
    (if default-schema
        (string-append (identifier schema) "." (identifier name))
        (identifier name)))
  (~> template
      (string-replace "{table-literal}" (in-string quoted))
      (string-replace "{table}" quoted)
      (string-replace "{schema}" (in-string schema))
      (string-replace "{name}" (in-string name))))

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
