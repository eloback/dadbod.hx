;; Where dadbod-ui keeps query files: a folder per database under
;; $XDG_DATA_HOME/dadbod-ui (by default ~/.local/share/dadbod-ui).
;;
;;   <label>/<name>.sql           a query: listed in the drawer as saved
;;   <label>/helpers/<name>.sql   the last query each table helper wrote
;;
;; No Helix, and nothing of dadbod.

(provide data-dir
         folder-name
         entry-dir
         query-file?
         label-of-file
         saved-queries
         new-query-file!
         helper-file!
         delete-query!
         read-text
         option
         set-option!)

(define (getenv name)
  (with-handler (lambda (_) #f)
                (let ([value (env-var name)])
                  (and (> (string-length value) 0) value))))

(define (data-dir)
  (string-append (or (getenv "XDG_DATA_HOME") (string-append (or (getenv "HOME") "") "/.local/share"))
                 "/dadbod-ui"))

(define (safe-char? ch)
  (or (and (char>=? ch #\a) (char<=? ch #\z))
      (and (char>=? ch #\A) (char<=? ch #\Z))
      (and (char>=? ch #\0) (char<=? ch #\9))
      (member ch (list #\_ #\. #\-))))

;; A label as a folder or file name: anything but letters, digits, _ . -
;; becomes _, and it never starts with a dot.
(define (folder-name label)
  (define cleaned
    (list->string (map (lambda (ch) (if (safe-char? ch) ch #\_)) (string->list label))))
  (cond
    [(string=? cleaned "") "_"]
    [(starts-with? cleaned ".") (string-append "_" cleaned)]
    [else cleaned]))

(define (entry-dir label)
  (string-append (data-dir) "/" (folder-name label)))

;; Makes `dir` if it isn't there. The data directory itself is made for the
;; user only: saved queries can hold anything.
(define (ensure-dir! dir)
  (unless (is-dir? (data-dir))
    (create-directory! (data-dir))
    (with-handler (lambda (_) #f)
                  (~> (command "chmod" (list "700" (data-dir)))
                      with-stdout-piped
                      with-stderr-piped
                      spawn-process
                      Ok->value
                      wait)))
  (unless (is-dir? dir)
    (create-directory! dir))
  dir)

;; A path with its symlinks resolved, or as it is when that can't be done.
;; Helix reports a file's path resolved; the data directory may be behind a
;; link (a home on another disk), so the two are compared resolved.
(define (resolved path)
  (with-handler (lambda (_) path) (canonicalize-path path)))

;; A query file's path below the data directory ("shop/query-1.sql"), or #f
;; when it isn't one of dadbod-ui's.
(define (below-data-dir path)
  (define root (string-append (resolved (data-dir)) "/"))
  (define full (and (string? path) (resolved path)))
  (and full
       (starts-with? full root)
       (ends-with? full ".sql")
       (substring full (string-length root) (string-length full))))

;; Whether `path` is one of dadbod-ui's query files.
(define (query-file? path)
  (and (below-data-dir path) #t))

;; The folder name of the database a query file belongs to.
(define (label-of-file path)
  (car (split-many (below-data-dir path) "/")))

;; The saved queries of a database: its .sql files' names, sorted.
(define (saved-queries label)
  (define dir (entry-dir label))
  (if (is-dir? dir)
      (sort (filter (lambda (name) (ends-with? name ".sql")) (map file-name (read-dir dir))) string<?)
      '()))

(define (write-text! path text)
  (define port (open-output-file path #:exists 'truncate))
  (write-string text port)
  (close-output-port port))

(define (read-text path)
  (define port (open-input-file path))
  (define text (read-port-to-string port))
  (close-input-port port)
  text)

;; Makes an empty query file for a database, named query-N.sql with the
;; first N that is free, and returns its path.
(define (new-query-file! label)
  (define dir (ensure-dir! (entry-dir label)))
  (let loop ([n 1])
    (define path (string-append dir "/query-" (number->string n) ".sql"))
    (if (path-exists? path)
        (loop (+ n 1))
        (begin
          (write-text! path "")
          path))))

;; Writes the SQL of a table helper to its file and returns the path.
(define (helper-file! label table helper sql)
  (define dir (ensure-dir! (string-append (ensure-dir! (entry-dir label)) "/helpers")))
  (define path (string-append dir "/" (folder-name table) "." (folder-name helper) ".sql"))
  (write-text! path (string-append sql "\n"))
  path)

(define (delete-query! label file)
  (delete-file! (string-append (entry-dir label) "/" file)))

;;; Options, set from init.scm through dadbod-ui/config.scm

(define *options* (hash 'execute-on-save #f 'run-helpers #t))

(define (option name)
  (hash-try-get *options* name))

(define (set-option! name value)
  (unless (hash-contains? *options* name)
    (error (string-append "dadbod-ui has no option called " (symbol->string name))))
  (set! *options* (hash-insert *options* name value)))
