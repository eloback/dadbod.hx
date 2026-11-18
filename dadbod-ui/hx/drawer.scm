;; The drawer in Helix: keeps the one drawer (core/drawer.scm), shows it in
;; a floating list over the editor, and does what selecting a line asks for,
;; through dadbod's API.
;;
;; It floats, like Helix's pickers, rather than sitting in a window: Helix
;; can't give a split a width, and a buffer of its own would take the place
;; of what the user was looking at.
;;
;; Nothing here looks a connection up (which can run its command) except
;; what the user asks for by pressing a key on it: listing a database's
;; tables, running a helper.

(require "editor.scm")
(require "../core/drawer.scm")
(require "../core/store.scm")
(require "../../dadbod/api.scm")

(provide open-command!)

(define NAME "dadbod-ui")

;;; State. Only touched on the main thread.

(define *drawer* (new-drawer))
;; The line the cursor is on, among the lines shown.
(define *cursor* 0)

(define (reporting-errors thunk)
  (with-handler (lambda (err)
                  (error-status! (string-append "dbui: " (trim (error-object-message err)))))
                (thunk)))

;;; The databases

(define CURRENT "current database")

;; The connections there are, and after them the database dadbod is using
;; when that isn't one of them (a URL, or $DATABASE_URL).
(define (entries-now)
  (define names (dadbod-connection-names))
  (define current (dadbod-current))
  (append (map (lambda (name) (entry name name "")) names)
          (if (and current (not (member current names)))
              (list (entry CURRENT current (with-handler (lambda (_) "") (dadbod-display current))))
              '())))

(define (entry-labelled label)
  (define found (filter (lambda (e) (equal? (entry-label e) label)) (drawer-entries *drawer*)))
  (and (not (null? found)) (car found)))

(define (database-of label)
  (define found (entry-labelled label))
  (unless found
    (error (string-append "'" label "' is no longer in the drawer")))
  (entry-database found))

(define (reload-entries!)
  (define before (drawer-entries *drawer*))
  (set! *drawer* (with-entries *drawer* (entries-now)))
  (for-each
   (lambda (e)
     (define label (entry-label e))
     (define old (filter (lambda (b) (equal? (entry-label b) label)) before))
     ;; The same label for another database ("current database" after the
     ;; database in use changed): what was known is about the old one.
     (when (and (not (null? old)) (not (equal? (entry-database (car old)) (entry-database e))))
       (set! *drawer* (forget-database *drawer* label)))
     (set! *drawer* (with-saved *drawer* label (saved-queries label))))
   (drawer-entries *drawer*)))

;; The database a query file of dadbod-ui's belongs to: the one whose folder
;; it is in. #f for any other file, or a folder no database has now.
(define (database-of-query-file path)
  (and (query-file? path)
       (begin
         (when (null? (drawer-entries *drawer*))
           (reload-entries!))
         (let* ([folder (label-of-file path)]
                [found (filter (lambda (e) (equal? (folder-name (entry-label e)) folder))
                               (drawer-entries *drawer*))])
           (and (not (null? found)) (entry-database (car found)))))))

;;; What is shown
;;
;; The model's first line is its title, which the box shows on its edge: the
;; lines shown are the rest.

(define (shown-lines)
  (cdr (drawer-lines *drawer*)))

(define (clamp-cursor!)
  (set! *cursor* (max 0 (min *cursor* (- (length (shown-lines)) 1)))))

(define (current-node)
  (define lines (shown-lines))
  (if (and (>= *cursor* 0) (< *cursor* (length lines)))
      (line-node (list-ref lines *cursor*))
      (list 'title)))

;; Changes the drawer with `change!` and keeps the cursor on the node it was
;; on, wherever that line has moved to; on the same line number if the node
;; is gone.
(define (keeping-cursor change!)
  (define node (current-node))
  (change!)
  (let ([line (line-of-node (shown-lines) node)])
    (when line
      (set! *cursor* line)))
  (clamp-cursor!))

(define (view)
  (list "dadbod-ui"
        (map line-text (shown-lines))
        *cursor*
        (if (drawer-help? *drawer*) "? hide help" "? help   ret open   q close")))

;;; Tables

(define (first-line path)
  (with-handler (lambda (_) "")
                (car (split-many (string-append (read-text path) "\n") "\n"))))

(define (load-tables! label)
  (define (failed! text)
    (keeping-cursor (lambda () (set! *drawer* (with-tables *drawer* label (list 'failed text))))))
  ;; Looking the database up can fail (an unset variable, a command), and so
  ;; can starting the client: either way it is shown where the tables go.
  (define problem
    (with-handler
     (lambda (err) (trim (error-object-message err)))
     (let ([database (database-of label)])
       (set! *drawer* (with-helpers *drawer* label (dadbod-helpers database)))
       (dadbod-query!
        database
        (dadbod-tables-sql database)
        (lambda (failure stdout-file stderr-file)
          (if failure
              (let ([said (first-line stderr-file)])
                (failed! (if (string=? said "") failure said)))
              (keeping-cursor
               (lambda ()
                 (set! *drawer*
                       (with-tables *drawer*
                                    label
                                    (with-handler (lambda (_) (list 'failed "the table names are not UTF-8"))
                                                  (parse-table-list (read-text stdout-file))))))))))
       #f)))
  (when problem
    (failed! problem)))

;;; What a selection does
;;
;; Returns 'close when the drawer has done its job and gets out of the way:
;; a query was opened.

(define (perform! action)
  (define kind (car action))
  (cond
    [(equal? kind 'load-tables)
     (load-tables! (cadr action))
     'stay]
    [(equal? kind 'new-query)
     (open-file! (new-query-file! (cadr action)))
     'close]
    [(equal? kind 'open-saved)
     (open-file! (string-append (entry-dir (cadr action)) "/" (caddr action)))
     'close]
    [(equal? kind 'run-helper)
     (let* ([label (cadr action)]
            [table (caddr action)]
            [helper (cadddr action)]
            [database (database-of label)]
            [sql (dadbod-helper-sql database helper table)])
       (open-file! (helper-file! label table helper sql))
       (when (option 'run-helpers)
         (dadbod-run! database sql))
       'close)]
    [else 'stay]))

(define (select!)
  (define selected (select *drawer* (current-node)))
  (keeping-cursor (lambda () (set! *drawer* (car selected))))
  (perform! (cadr selected)))

;; R: the database under the cursor is asked for its tables again, and its
;; saved queries are read again.
(define (refresh!)
  (define node (current-node))
  (keeping-cursor
   (lambda ()
     (reload-entries!)
     (when (and (pair? (cdr node)) (entry-labelled (cadr node)))
       (set! *drawer* (with-tables *drawer* (cadr node) 'loading))
       (load-tables! (cadr node))))))

;; A: "name reference" is added to the user's connections.
(define (add!)
  (ask! "connection (name, then a URL without a password, $VARIABLE or !command): "
        (lambda (answer)
          (reporting-errors
           (lambda ()
             (define words (filter (lambda (w) (not (string=? w ""))) (split-many (trim answer) " ")))
             (when (or (null? words) (null? (cdr words)))
               (error "give a name and, after a space, where its URL comes from"))
             (dadbod-add-connection! (car words) (string-join (cdr words) " "))
             (reload-entries!)
             (let ([line (line-of-node (shown-lines) (list 'entry (car words)))])
               (when line
                 (set! *cursor* line)))
             (status! (string-append "dbui: added " (car words))))))))

;; d: on a saved query, deletes it after asking.
(define (delete!)
  (define node (current-node))
  (unless (equal? (car node) 'saved)
    (error "d deletes a saved query: put the cursor on one"))
  (ask! (string-append "delete " (caddr node) "? (y/n): ")
        (lambda (answer)
          (reporting-errors (lambda ()
                              (when (equal? (trim answer) "y")
                                (delete-query! (cadr node) (caddr node))
                                (keeping-cursor reload-entries!)
                                (status! (string-append "dbui: deleted " (caddr node)))))))))

(define (move! by)
  (set! *cursor* (+ *cursor* by))
  (clamp-cursor!))

;; A key pressed in the drawer. Returns 'close to close it.
(define (on-key key)
  (cond
    [(member key (list "j" "down")) (move! 1)]
    [(member key (list "k" "up")) (move! -1)]
    [(equal? key "g") (set! *cursor* 0)]
    [(equal? key "G")
     (set! *cursor* (length (shown-lines)))
     (clamp-cursor!)]
    [(member key (list "ret" "o" "l")) (reporting-errors select!)]
    [(equal? key "R") (reporting-errors refresh!)]
    [(equal? key "A") (reporting-errors add!)]
    [(equal? key "d") (reporting-errors delete!)]
    [(equal? key "?") (keeping-cursor (lambda () (set! *drawer* (toggle-help *drawer*))))]
    [(member key (list "q" "esc")) 'close]
    [else 'stay]))

;;; Commands

;; :dbui
(define (open-command!)
  (reporting-errors (lambda ()
                      (keeping-cursor reload-entries!)
                      ;; Not twice, if :dbui is given while it is open.
                      (close-float! NAME)
                      (open-float! NAME view on-key))))

;;; Set up, once, when the plugin is loaded

;; A query file in a database's folder runs against that database, however
;; it was opened and whatever it was renamed to there.
(dadbod-database-of-file! database-of-query-file)

;; With the option on, saving a query file runs it, against the database
;; :db-run would use in it.
(on-file-saved!
 (lambda (path text)
   (when (and (option 'execute-on-save) (query-file? path))
     (reporting-errors (lambda ()
                         (define database (dadbod-database-of-file path))
                         (when database
                           (dadbod-run! database text)))))))
