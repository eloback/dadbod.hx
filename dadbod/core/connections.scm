;; Named connections: `:db-run prod` instead of a URL.
;;
;; A connection is a name and a reference to its URL. The reference is
;;
;;   postgres://app@db.example.com/shop     the URL itself
;;   $SHOP_DATABASE_URL                     an environment variable holding it
;;   !pass show databases/shop              a command printing it
;;
;; The last two keep passwords out of files: the URL is looked up when a
;; query runs, never stored.
;;
;; Connections also come from the environment: see environment-connections.
;;
;; Connections are written one per line, name first:
;;
;;   # comment
;;   prod   !pass show databases/shop
;;   dev    postgres:///shop_dev
;;
;; Pure: reading the files, the environment and running the command are the
;; caller's (hx/commands.scm), passed in where needed.
;;
;; No Helix.

(provide connection
         connection?
         connection-name
         connection-reference
         connection-source
         connection-name?
         parse-connections
         environment-connections
         merge-connections
         find-connection
         format-connection
         resolve-reference)

;; name       letters, digits, _ . -
;; reference  see above
;; source     where it was defined, for the user: a file's path, "init.scm"
(struct connection (name reference source))

(define (name-char? ch)
  (or (and (char>=? ch #\a) (char<=? ch #\z))
      (and (char>=? ch #\A) (char<=? ch #\Z))
      (and (char>=? ch #\0) (char<=? ch #\9))
      (member ch (list #\_ #\. #\-))))

;; Whether `text` can be a connection's name. A URL can't: it has a colon.
(define (connection-name? text)
  (and (string? text)
       (> (string-length text) 0)
       (null? (filter (lambda (ch) (not (name-char? ch))) (string->list text)))))

(define (first-of text ch)
  (define len (string-length text))
  (let loop ([i 0])
    (cond
      [(>= i len) #f]
      [(char=? (string-ref text i) ch) i]
      [else (loop (+ i 1))])))

(define (first-whitespace text)
  (define len (string-length text))
  (let loop ([i 0])
    (cond
      [(>= i len) #f]
      [(member (string-ref text i) (list #\space #\tab)) i]
      [else (loop (+ i 1))])))

;; Parses the text of a connections file. Returns
;; (list connections problems): the connections in the file's order, and one
;; line of text per line that couldn't be read.
(define (parse-connections text source)
  (let loop ([lines (split-many text "\n")] [number 1] [found '()] [problems '()])
    (if (null? lines)
        (list (reverse found) (reverse problems))
        (let* ([line (trim (car lines))]
               [space (first-whitespace line)]
               [name (if space (substring line 0 space) line)]
               [reference (if space (trim (substring line space (string-length line))) "")]
               [problem (lambda (what)
                          (string-append source ", line " (number->string number) ": " what))])
          (cond
            [(or (string=? line "") (starts-with? line "#"))
             (loop (cdr lines) (+ number 1) found problems)]
            [(not (connection-name? name))
             (loop (cdr lines)
                   (+ number 1)
                   found
                   (cons (problem "a connection's name is letters, digits, _ . and -") problems))]
            [(string=? reference "")
             (loop (cdr lines)
                   (+ number 1)
                   found
                   (cons (problem (string-append "'" name "' has no URL after it")) problems))]
            [else
             (loop (cdr lines)
                   (+ number 1)
                   (cons (connection name reference source) found)
                   problems)])))))

;; The connections the environment defines, as vim-dadbod-ui has them: a
;; variable DB_UI_<NAME> holding a URL is the connection <name>, lowercased.
;; `listing` is what `env` prints: NAME=value lines.
;;
;; The value is the URL itself. One that starts with "!" is left out: a
;; variable is not a place to put a command to run.
(define (environment-connections listing)
  (define prefix "DB_UI_")
  (define (from-line line)
    (define equals (first-of line #\=))
    (and (starts-with? line prefix)
         equals
         (let ([name (string-downcase (substring line (string-length prefix) equals))]
               [value (trim (substring line (+ equals 1) (string-length line)))])
           (and (connection-name? name)
                (not (string=? value ""))
                (not (starts-with? value "!"))
                (connection name value (string-append "$" (substring line 0 equals)))))))
  (filter (lambda (found) found) (map from-line (split-many listing "\n"))))

;; One list out of several, each a list of connections. A name defined in a
;; later list replaces the earlier one, in the earlier one's place.
(define (merge-connections lists)
  (define all (apply append lists))
  (define (last-with name)
    (car (reverse (filter (lambda (c) (equal? (connection-name c) name)) all))))
  (let loop ([rest all] [seen '()] [result '()])
    (cond
      [(null? rest) (reverse result)]
      [(member (connection-name (car rest)) seen) (loop (cdr rest) seen result)]
      [else
       (loop (cdr rest)
             (cons (connection-name (car rest)) seen)
             (cons (last-with (connection-name (car rest))) result))])))

;; The connection called `name`, or #f.
(define (find-connection connections name)
  (define found (filter (lambda (c) (equal? (connection-name c) name)) connections))
  (and (not (null? found)) (car found)))

;; A connection as a line of a connections file.
(define (format-connection c)
  (string-append (connection-name c) " " (connection-reference c)))

;; The URL a reference stands for, as text.
;;   getenv        (name) -> the variable's value, or #f
;;   run-command   (text) -> what the shell command prints; raises when it fails
;; Raises an error with a message for the user when it can't be looked up.
;; The messages never quote what was looked up: that is the secret.
(define (resolve-reference reference getenv run-command)
  (cond
    [(starts-with? reference "$")
     (let* ([variable (substring reference 1 (string-length reference))]
            [value (getenv variable)])
       (unless value
         (error (string-append "the environment variable " variable " is not set")))
       (trim value))]
    [(starts-with? reference "!")
     (let* ([text (trim (substring reference 1 (string-length reference)))]
            ;; An error can't be raised from inside a handler (it crashes
            ;; Steel), so the handler hands the failure out as a value.
            [output (with-handler (lambda (err) (list 'failed (trim (error-object-message err))))
                                  (run-command text))]
            [url (if (string? output) (trim output) "")])
       (when (list? output)
         (error (string-append "the command for the URL failed: " (cadr output))))
       (when (string=? url "")
         (error "the command for the URL printed nothing"))
       ;; The URL is its first line: a password manager may print more.
       (car (split-many url "\n")))]
    [else reference]))
