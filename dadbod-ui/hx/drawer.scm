;; The drawer in Helix: keeps the one drawer (core/drawer.scm), draws it
;; into a panel, and does what selecting a line asks for, through dadbod's
;; API.
;;
;; The drawer opens in the focused window rather than beside it: Helix
;; can't give a split a width, so a side panel would take half the screen.
;;
;; Nothing here looks a connection up (which can run its command) except
;; what the user asks for by pressing a key on it: listing a database's
;; tables, running a helper.

(require "editor.scm")
(require "../core/drawer.scm")
(require "../core/store.scm")
(require "../../dadbod/api.scm")

(provide open-command!
         select-command!
         refresh-command!
         add-command!
         delete-command!
         help-command!
         close-command!)

(define PANEL "*dadbod-ui*")

;;; State. Only touched on the main thread.

(define *drawer* (new-drawer))
;; The panel's document while it is open.
(define *doc* #f)
;; The lines last drawn into the panel. What the user sees, and so what the
;; cursor's line is read against: the model can have moved on since (tables
;; arrive while another window has the focus).
(define *drawn* '())
;; The line the cursor was on when the drawer was last used.
(define *line* 1)

(define (reporting-errors command thunk)
  (with-handler (lambda (err)
                  (error-status! (string-append command ": " (trim (error-object-message err)))))
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

;;; Drawing

(define (panel-focused?)
  (and (doc-open? *doc*) (equal? (focused-doc) *doc*)))

(define (texts lines)
  (map line-text lines))

;; Draws the drawer into the panel, with the cursor on the line of `node`,
;; or else on line `fallback`. Only when the panel is what the user is
;; looking at, in normal mode: otherwise it is drawn when next used.
(define (redraw! node fallback)
  (when (and (panel-focused?) (normal-mode?))
    (let* ([lines (drawer-lines *drawer*)]
           [wanted (or (and node (line-of-node lines node)) fallback)]
           [line (max 0 (min wanted (- (length lines) 1)))])
      (set-panel-text! (string-join (texts lines) "\n") line)
      (set! *drawn* lines)
      (set! *line* line))))

;; The node of the line the cursor is on, as drawn.
(define (current-node)
  (node-at *drawn* (cursor-line)))

;;; Tables

(define (first-line path)
  (with-handler (lambda (_) "")
                (car (split-many (string-append (read-text path) "\n") "\n"))))

(define (load-tables! label)
  (define (failed! text)
    (set! *drawer* (with-tables *drawer* label (list 'failed text))))
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
          ;; Where the cursor is, read before the lines change under it.
          (define node (and (panel-focused?) (current-node)))
          (if failure
              (let ([said (first-line stderr-file)])
                (failed! (if (string=? said "") failure said)))
              (set! *drawer*
                    (with-tables *drawer*
                                 label
                                 (with-handler (lambda (_) (list 'failed "the table names are not UTF-8"))
                                               (parse-table-list (read-text stdout-file))))))
          (redraw! node *line*)))
       #f)))
  (when problem
    (failed! problem)))

;;; Query files

(define (perform! action)
  (define kind (car action))
  (cond
    [(equal? kind 'load-tables) (load-tables! (cadr action))]
    [(equal? kind 'new-query) (open-file! (new-query-file! (cadr action)))]
    [(equal? kind 'open-saved) (open-file! (string-append (entry-dir (cadr action)) "/" (caddr action)))]
    [(equal? kind 'run-helper)
     (let* ([label (cadr action)]
            [table (caddr action)]
            [helper (cadddr action)]
            [database (database-of label)]
            [sql (dadbod-helper-sql database helper table)])
       (open-file! (helper-file! label table helper sql))
       (when (option 'run-helpers)
         (dadbod-run! database sql)))]
    [else #f]))

;;; Commands

(define (bind-keys!)
  (set-panel-keys! PANEL
                   (hash "ret"
                         ":dbui-select"
                         "o"
                         ":dbui-select"
                         "R"
                         ":dbui-refresh"
                         "A"
                         ":dbui-add"
                         "d"
                         ":dbui-delete"
                         "?"
                         ":dbui-help"
                         "q"
                         ":dbui-close")))

;; :dbui
(define (open-command!)
  (reporting-errors
   "dbui"
   (lambda ()
     (reload-entries!)
     ;; Now, not when the plugin was loaded: the keys are a copy of the
     ;; global ones, and init.scm may have added to those since.
     (bind-keys!)
     (if (doc-open? *doc*)
         (show-doc! *doc*)
         (set! *doc* (open-panel! PANEL)))
     (redraw! #f *line*))))

;; Runs a command of the drawer's: only in the drawer, and only when what
;; is drawn is the drawer as it is. If it has changed since (tables arrived
;; while another window had the focus), the key was pressed on a line that
;; no longer means what it shows: the drawer is drawn again instead.
(define (in-panel command thunk)
  (reporting-errors
   command
   (lambda ()
     (unless (panel-focused?)
       (error "this works in the drawer: open it with :dbui"))
     (set! *line* (cursor-line))
     (if (equal? (texts *drawn*) (texts (drawer-lines *drawer*)))
         (thunk)
         (begin
           (redraw! #f *line*)
           (status! "dbui: the drawer has changed since it was drawn; it is up to date now"))))))

;; ret
(define (select-command!)
  (in-panel "dbui"
            (lambda ()
              (define node (current-node))
              (define selected (select *drawer* node))
              (set! *drawer* (car selected))
              (redraw! node *line*)
              (perform! (cadr selected))
              (redraw! node *line*))))

;; R: the database under the cursor is asked for its tables again, and its
;; saved queries are read again.
(define (refresh-command!)
  (in-panel "dbui"
            (lambda ()
              (define node (current-node))
              (reload-entries!)
              (when (and (pair? (cdr node)) (entry-labelled (cadr node)))
                (set! *drawer* (with-tables *drawer* (cadr node) 'loading))
                (load-tables! (cadr node)))
              (redraw! node *line*))))

;; A: "name reference" is added to the user's connections.
(define (add-command!)
  (in-panel "dbui"
            (lambda ()
              (ask! "connection (name, then a URL without a password, $VARIABLE or !command): "
                    (lambda (answer)
                      (reporting-errors
                       "dbui"
                       (lambda ()
                         (define words (filter (lambda (w) (not (string=? w ""))) (split-many (trim answer) " ")))
                         (when (or (null? words) (null? (cdr words)))
                           (error "give a name and, after a space, where its URL comes from"))
                         (dadbod-add-connection! (car words) (string-join (cdr words) " "))
                         (reload-entries!)
                         (redraw! (list 'entry (car words)) *line*)
                         (status! (string-append "dbui: added " (car words))))))))))

;; d: on a saved query, deletes it after asking.
(define (delete-command!)
  (in-panel "dbui"
            (lambda ()
              (define node (current-node))
              (unless (equal? (car node) 'saved)
                (error "d deletes a saved query: put the cursor on one"))
              (ask! (string-append "delete " (caddr node) "? (y/n): ")
                    (lambda (answer)
                      (reporting-errors
                       "dbui"
                       (lambda ()
                         (when (equal? (trim answer) "y")
                           (delete-query! (cadr node) (caddr node))
                           (reload-entries!)
                           (redraw! #f *line*)
                           (status! (string-append "dbui: deleted " (caddr node)))))))))))

;; ?
(define (help-command!)
  (in-panel "dbui"
            (lambda ()
              (define node (current-node))
              (set! *drawer* (toggle-help *drawer*))
              (redraw! node *line*))))

;; q
(define (close-command!)
  (in-panel "dbui"
            (lambda ()
              (close-focused-buffer!)
              (set! *doc* #f)
              (set! *drawn* '()))))

;;; Set up, once, when the plugin is loaded

;; The drawer's own text is not a query.
(dadbod-not-a-query!
 (lambda ()
   (and (panel-focused?) "this is the drawer: open a query from it (ret on New query)")))

;; A query file in a database's folder runs against that database, however
;; it was opened and whatever it was renamed to there.
(dadbod-database-of-file! database-of-query-file)

;; With the option on, saving a query file runs it, against the database
;; :db-run would use in it.
(on-file-saved!
 (lambda (path text)
   (when (and (option 'execute-on-save) (query-file? path))
     (reporting-errors "dbui"
                       (lambda ()
                         (define database (dadbod-database-of-file path))
                         (when database
                           (dadbod-run! database text)))))))
