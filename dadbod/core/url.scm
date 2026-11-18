;; Database URLs.
;;
;;   scheme://[user[:password]@][host][:port][/path][?query]
;;   scheme:path[?query]                 (no authority: sqlite:notes.db)
;;
;; A URL that could be read two ways is an error, not a guess: a wrong guess
;; connects to the wrong place or leaves a password where it gets shown.
;; Error messages never quote the URL's user, password or host part.
;;
;; Pure Steel, no Helix: unit-tested with `steel tests/unit.scm`.

(provide parse-url
         db-url?
         db-url-scheme
         db-url-authority?
         db-url-user
         db-url-password
         db-url-host
         db-url-port
         db-url-path
         db-url-query
         db-url-params
         db-url-without-password
         db-url-display
         percent-decode)

;; scheme            lowercase, without the colon
;; authority?        #t for scheme://…, #f for scheme:path
;; user, password    percent-decoded, or #f
;; host              percent-decoded, without IPv6 brackets, or #f
;; port              integer, or #f
;; path              percent-decoded, with its leading slash if it has one;
;;                   "" when absent
;; query             raw text after "?", or #f
;; without-password  the URL as given, minus the password: safe in argv
;; display           without-password minus the query: safe to show
(struct db-url
        (scheme authority? user password host port path query without-password display))

;; The query string as (name . value) pairs, in order, both percent-decoded.
;; A parameter without "=" has the value "".
(define (db-url-params url)
  (define query (db-url-query url))
  (define (pair part)
    (define equals (index-of-any part (list #\=)))
    (if equals
        (cons (percent-decode (substring part 0 equals))
              (percent-decode (substring part (+ equals 1) (string-length part))))
        (cons (percent-decode part) "")))
  (if query
      (map pair (filter (lambda (part) (> (string-length part) 0)) (split-many query "&")))
      '()))

(define (index-of-any s chars)
  (define len (string-length s))
  (let loop ([i 0])
    (cond
      [(>= i len) #f]
      [(member (string-ref s i) chars) i]
      [else (loop (+ i 1))])))

(define (last-index-of s ch)
  (let loop ([i (- (string-length s) 1)])
    (cond
      [(< i 0) #f]
      [(char=? (string-ref s i) ch) i]
      [else (loop (- i 1))])))

(define (count-char s ch)
  (length (filter (lambda (c) (char=? c ch)) (string->list s))))

(define (hex-value byte)
  (cond
    [(and (>= byte 48) (<= byte 57)) (- byte 48)] ; 0-9
    [(and (>= byte 65) (<= byte 70)) (- byte 55)] ; A-F
    [(and (>= byte 97) (<= byte 102)) (- byte 87)] ; a-f
    [else #f]))

;; Decodes %XX escapes. A "%" that isn't followed by two hex digits is kept
;; as it is, and so is the whole string if the result isn't valid UTF-8.
;; "+" stays a plus: this is a URI, not a form.
(define (percent-decode s)
  (define (decode-bytes bytes)
    (cond
      [(null? bytes) '()]
      [(and (= (car bytes) 37) ; %
            (not (null? (cdr bytes)))
            (not (null? (cddr bytes)))
            (hex-value (cadr bytes))
            (hex-value (caddr bytes)))
       (cons (+ (* 16 (hex-value (cadr bytes))) (hex-value (caddr bytes)))
             (decode-bytes (cdddr bytes)))]
      [else (cons (car bytes) (decode-bytes (cdr bytes)))]))
  (if (string-contains? s "%")
      (with-handler (lambda (_) s)
                    (bytes->string/utf8 (list->bytes (decode-bytes (bytes->list (string->bytes s))))))
      s))

(define (non-empty s)
  (and (string? s) (> (string-length s) 0) s))

(define (decoded s)
  (and (non-empty s) (percent-decode s)))

(define encode-hint "percent-encode / ? # @ and : in the user and password, like %2F for /")

;; "host", "host:5432", "[::1]", "[::1]:5432" -> (list host port-text), each
;; a string or #f.
(define (split-host-port hostport)
  (cond
    [(starts-with? hostport "[")
     (let ([close (last-index-of hostport #\])])
       (unless close
         (error "database URL has an unclosed '[' in its host"))
       (let ([after (substring hostport (+ close 1) (string-length hostport))])
         (list (substring hostport 1 close)
               (cond
                 [(string=? after "") #f]
                 [(starts-with? after ":") (substring after 1 (string-length after))]
                 [else (error "database URL has text after its bracketed host")]))))]
    [(> (count-char hostport #\:) 1)
     (error "database URL has several ':' in its host: write an IPv6 address in brackets, like [::1]:5432")]
    [else
     (let ([colon (last-index-of hostport #\:)])
       (if colon
           (list (substring hostport 0 colon)
                 (substring hostport (+ colon 1) (string-length hostport)))
           (list hostport #f)))]))

(define (digit? ch)
  (and (char>=? ch #\0) (char<=? ch #\9)))

;; Digits only: string->number alone would also take 1e3, #x1F90 or 5432.0.
;; The text isn't quoted in the error: after a password with a raw "/" in it,
;; what sits in the port's place is a piece of the password.
(define (parse-port text)
  (cond
    [(not (non-empty text)) #f]
    [else
     (let ([port (and (<= (string-length text) 5)
                      (null? (filter (lambda (ch) (not (digit? ch))) (string->list text)))
                      (string->number text))])
       (unless (and port (> port 0) (< port 65536))
         (error (string-append "database URL has an invalid port (if that is not a port: "
                               encode-hint
                               ")")))
       port)]))

;; Parses `text` into a db-url. Raises an error with a message for the user
;; when it isn't one.
(define (parse-url text)
  (define trimmed (trim text))
  (define colon (index-of-any trimmed (list #\:)))
  (unless (and colon (> colon 0))
    (error "not a database URL: expected scheme://… or scheme:path"))
  (define scheme (string-downcase (substring trimmed 0 colon)))
  (define rest (substring trimmed (+ colon 1) (string-length trimmed)))

  (cond
    ;; scheme://authority/path?query
    [(starts-with? rest "//")
     (let* ([after (substring rest 2 (string-length rest))]
            [authority-end (or (index-of-any after (list #\/ #\?)) (string-length after))]
            [authority (substring after 0 authority-end)]
            [tail (substring after authority-end (string-length after))]
            [question (index-of-any tail (list #\?))]
            [path (if question (substring tail 0 question) tail)]
            [query (and question (substring tail (+ question 1) (string-length tail)))]
            ;; The last "@": a password with a raw "@" in it still parses.
            [at (last-index-of authority #\@)]
            [userinfo (and at (substring authority 0 at))]
            [hostport (if at (substring authority (+ at 1) (string-length authority)) authority)]
            [user-colon (and userinfo (index-of-any userinfo (list #\:)))]
            [user (if user-colon (substring userinfo 0 user-colon) userinfo)]
            [password
             (and user-colon (substring userinfo (+ user-colon 1) (string-length userinfo)))])
       ;; An "@" after the authority means the authority ended early, at a raw
       ;; "/" or "?" inside the user or password. Parsing on would take a piece
       ;; of the password for the host and leave the rest in the path.
       (when (string-contains? tail "@")
         (error (string-append "database URL has an '@' after its host: " encode-hint)))
       (let* ([host+port (split-host-port hostport)]
              [port (parse-port (cadr host+port))]
              [without-password-prefix
               (string-append scheme "://" (if userinfo (string-append user "@") "") hostport path)])
         (db-url scheme
                 #t
                 (decoded user)
                 (decoded password)
                 (decoded (car host+port))
                 port
                 (percent-decode path)
                 query
                 (if query
                     (string-append without-password-prefix "?" query)
                     without-password-prefix)
                 without-password-prefix)))]

    ;; scheme:path?query
    [else
     (let* ([question (index-of-any rest (list #\?))]
            [path (if question (substring rest 0 question) rest)]
            [query (and question (substring rest (+ question 1) (string-length rest)))]
            [display (string-append scheme ":" path)])
       (db-url scheme
               #f
               #f
               #f
               #f
               #f
               (percent-decode path)
               query
               (if query (string-append display "?" query) display)
               display))]))
