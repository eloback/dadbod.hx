;; The drawer's model: what there is to show, what is expanded, the lines it
;; becomes, and what selecting a line means.
;;
;; Pure. hx/drawer.scm keeps the one current drawer, draws its lines into a
;; buffer and carries out what a selection asks for.
;;
;; No Helix, and nothing of dadbod.

(provide new-drawer
         drawer?
         drawer-entries
         drawer-help?
         entry
         entry-label
         entry-database
         entry-detail
         with-entries
         with-saved
         with-tables
         with-helpers
         forget-database
         toggle-help
         select
         drawer-lines
         line-text
         line-node
         node-at
         line-of-node
         parse-table-list)

;; One database in the drawer.
;;   label     what it is called in the drawer, and its folder's name
;;   database  what dadbod runs against: a connection's name or a URL
;;   detail    shown after the label (where it is defined), or ""
(struct entry (label database detail))

;; entries   the databases, in order
;; expanded  the keys of the expanded nodes (see key-of)
;; saved     label -> the names of its saved query files
;; tables    label -> 'loading, a list of table names, or (list 'failed text)
;; helpers   label -> the names of the helpers its tables offer
;; help?     whether the keys are shown
(struct drawer (entries expanded saved tables helpers help?))

(define (new-drawer)
  (drawer '() '() (hash) (hash) (hash) #f))

(define (with-entries d entries)
  (drawer entries (drawer-expanded d) (drawer-saved d) (drawer-tables d) (drawer-helpers d) (drawer-help? d)))

(define (with-expanded d expanded)
  (drawer (drawer-entries d) expanded (drawer-saved d) (drawer-tables d) (drawer-helpers d) (drawer-help? d)))

;; The saved queries of `label` are `files`.
(define (with-saved d label files)
  (drawer (drawer-entries d)
          (drawer-expanded d)
          (hash-insert (drawer-saved d) label files)
          (drawer-tables d)
          (drawer-helpers d)
          (drawer-help? d)))

;; The tables of `label` are `tables`: 'loading, a list of names, or
;; (list 'failed text).
(define (with-tables d label tables)
  (drawer (drawer-entries d)
          (drawer-expanded d)
          (drawer-saved d)
          (hash-insert (drawer-tables d) label tables)
          (drawer-helpers d)
          (drawer-help? d)))

(define (with-helpers d label helpers)
  (drawer (drawer-entries d)
          (drawer-expanded d)
          (drawer-saved d)
          (drawer-tables d)
          (hash-insert (drawer-helpers d) label helpers)
          (drawer-help? d)))

;; Forgets what is known about the database of `label`: its tables and
;; helpers. For when the label now stands for another database.
(define (forget-database d label)
  (drawer (drawer-entries d)
          (drawer-expanded d)
          (drawer-saved d)
          (hash-remove (drawer-tables d) label)
          (hash-remove (drawer-helpers d) label)
          (drawer-help? d)))

(define (toggle-help d)
  (drawer (drawer-entries d)
          (drawer-expanded d)
          (drawer-saved d)
          (drawer-tables d)
          (drawer-helpers d)
          (not (drawer-help? d))))

;;; Nodes
;;
;; A node is what a line stands for, a list:
;;   (title)                          the first line
;;   (help)                           a line of the key help
;;   (entry <label>)                  a database
;;   (new-query <label>)
;;   (saved-section <label>)
;;   (saved <label> <file>)           a saved query
;;   (tables-section <label>)
;;   (table <label> <table>)
;;   (helper <label> <table> <name>)  a ready-made query about a table
;;   (note <label>)                   "loading…", an error, "(none)"

;; The nodes that open and close, as the key they are remembered under.
(define (key-of node)
  (define kind (car node))
  (cond
    [(equal? kind 'entry) (string-append "entry " (cadr node))]
    [(equal? kind 'saved-section) (string-append "saved " (cadr node))]
    [(equal? kind 'tables-section) (string-append "tables " (cadr node))]
    [(equal? kind 'table) (string-append "table " (cadr node) " " (caddr node))]
    [else #f]))

(define (expanded? d node)
  (and (key-of node) (member (key-of node) (drawer-expanded d)) #t))

(define (toggled d node)
  (define key (key-of node))
  (with-expanded d
                 (if (member key (drawer-expanded d))
                     (filter (lambda (k) (not (equal? k key))) (drawer-expanded d))
                     (cons key (drawer-expanded d)))))

;;; Selecting
;;
;; (select drawer node) -> (list drawer action). The action is what the
;; caller has to do, a list:
;;   (none)
;;   (load-tables <label>)            ask the database for its tables
;;   (new-query <label>)              make a query file and open it
;;   (open-saved <label> <file>)      open a saved query
;;   (run-helper <label> <table> <name>)

(define (select d node)
  (define kind (car node))
  (cond
    [(member kind (list 'entry 'saved-section 'table)) (list (toggled d node) (list 'none))]
    [(equal? kind 'tables-section)
     (let* ([label (cadr node)]
            [opening? (not (expanded? d node))]
            [known (hash-try-get (drawer-tables d) label)])
       ;; Asked for once, when first opened. `R` asks again.
       (if (and opening? (not known))
           (list (with-tables (toggled d node) label 'loading) (list 'load-tables label))
           (list (toggled d node) (list 'none))))]
    [(equal? kind 'new-query) (list d (list 'new-query (cadr node)))]
    [(equal? kind 'saved) (list d (list 'open-saved (cadr node) (caddr node)))]
    [(equal? kind 'helper) (list d (cons 'run-helper (cdr node)))]
    [else (list d (list 'none))]))

;;; Lines

(struct line (text node))

(define (marker d node)
  (if (expanded? d node) "▾ " "▸ "))

(define help-lines
  (list "  j k  move (also the arrows, g, G)      ret  open or close, run a helper"
        "  R    ask for the tables again          A    add a connection"
        "  d    delete a saved query              q    close (also esc)"))

(define (count-of items)
  (string-append " (" (number->string (length items)) ")"))

(define (table-lines d label)
  (define tables (hash-try-get (drawer-tables d) label))
  (define helpers (or (hash-try-get (drawer-helpers d) label) '()))
  (cond
    [(or (not tables) (equal? tables 'loading)) (list (line "      loading…" (list 'note label)))]
    [(and (pair? tables) (equal? (car tables) 'failed))
     (list (line (string-append "      " (cadr tables)) (list 'note label)))]
    [(null? tables) (list (line "      (no tables)" (list 'note label)))]
    [else
     (apply append
            (map (lambda (table)
                   (define node (list 'table label table))
                   (cons (line (string-append "    " (marker d node) table) node)
                         (if (expanded? d node)
                             (map (lambda (helper)
                                    (line (string-append "        " helper) (list 'helper label table helper)))
                                  helpers)
                             '())))
                 tables))]))

(define (entry-lines d e)
  (define label (entry-label e))
  (define node (list 'entry label))
  (define saved (or (hash-try-get (drawer-saved d) label) '()))
  (define tables (hash-try-get (drawer-tables d) label))
  (define saved-node (list 'saved-section label))
  (define tables-node (list 'tables-section label))
  (cons (line (string-append (marker d node)
                             label
                             (if (string=? (entry-detail e) "") "" (string-append "  " (entry-detail e))))
              node)
        (if (expanded? d node)
            (append (list (line "    + New query" (list 'new-query label))
                          (line (string-append "  " (marker d saved-node) "Saved queries" (count-of saved))
                                saved-node))
                    (if (expanded? d saved-node)
                        (if (null? saved)
                            (list (line "      (none)" (list 'note label)))
                            (map (lambda (file) (line (string-append "      " file) (list 'saved label file)))
                                 saved))
                        '())
                    (list (line (string-append "  "
                                               (marker d tables-node)
                                               "Tables"
                                               (if (list? tables)
                                                   (if (and (pair? tables) (equal? (car tables) 'failed))
                                                       ""
                                                       (count-of tables))
                                                   ""))
                                tables-node))
                    (if (expanded? d tables-node) (table-lines d label) '()))
            '())))

;; The drawer as lines, top to bottom.
(define (drawer-lines d)
  (append (list (line (if (drawer-help? d) "dadbod-ui" "dadbod-ui    ? for help") (list 'title)))
          (if (drawer-help? d) (map (lambda (text) (line text (list 'help))) help-lines) '())
          (if (null? (drawer-entries d))
              (list (line "(no connections: press A to add one, or see the README)" (list 'note "")))
              (apply append (map (lambda (e) (entry-lines d e)) (drawer-entries d))))))

;; The node of the line at `index` (from 0), or (title) past the end.
(define (node-at lines index)
  (if (and (>= index 0) (< index (length lines)))
      (line-node (list-ref lines index))
      (list 'title)))

;; The index of the line standing for `node`, or #f.
(define (line-of-node lines node)
  (let loop ([rest lines] [index 0])
    (cond
      [(null? rest) #f]
      [(equal? (line-node (car rest)) node) index]
      [else (loop (cdr rest) (+ index 1))])))

;;; What the database answers

;; The table names in the output of a tables query: one per line.
(define (parse-table-list text)
  (filter (lambda (name) (not (string=? name ""))) (map trim (split-many text "\n"))))
