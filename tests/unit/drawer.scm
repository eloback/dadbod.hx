;; dadbod-ui/core/drawer.scm and dadbod-ui/core/store.scm

(require "steel/tests/unit-test.scm")
(require "lib.scm")
(require "../../dadbod-ui/core/drawer.scm")
(require "../../dadbod-ui/core/store.scm")

(define (texts d)
  (map line-text (drawer-lines d)))

;; Selects the line showing `node`: the drawer afterwards.
(define (after-select d node)
  (car (select d node)))

(define (action-of d node)
  (cadr (select d node)))

(define two
  (with-entries (new-drawer)
                (list (entry "shop" "shop" "your connections") (entry "current database" "sqlite:a.db" ""))))

;;; Lines

(check-equal? "lines: no connections"
              (texts (new-drawer))
              (list "dadbod-ui    ? for help" "(no connections: press A to add one, or see the README)"))

(check-equal? "lines: connections start closed, with where they are defined"
              (texts two)
              (list "dadbod-ui    ? for help" "▸ shop  your connections" "▸ current database"))

(define open-shop (after-select two (list 'entry "shop")))

(check-equal? "lines: an open connection offers a new query, saved queries and tables"
              (texts open-shop)
              (list "dadbod-ui    ? for help"
                    "▾ shop  your connections"
                    "    + New query"
                    "  ▸ Saved queries (0)"
                    "  ▸ Tables"
                    "▸ current database"))

(check-equal? "lines: selecting an open connection closes it again"
              (texts (after-select open-shop (list 'entry "shop")))
              (texts two))

(check-equal? "lines: saved queries, listed when their section is open"
              (texts (after-select (with-saved open-shop "shop" (list "big.sql" "query-1.sql"))
                                   (list 'saved-section "shop")))
              (list "dadbod-ui    ? for help"
                    "▾ shop  your connections"
                    "    + New query"
                    "  ▾ Saved queries (2)"
                    "      big.sql"
                    "      query-1.sql"
                    "  ▸ Tables"
                    "▸ current database"))

(check-equal? "lines: an open, empty saved section says so"
              (list-ref (texts (after-select open-shop (list 'saved-section "shop"))) 4)
              "      (none)")

(check-equal? "lines: help is shown and hidden"
              (list (length (texts (toggle-help two))) (texts (toggle-help (toggle-help two))))
              (list 6 (texts two)))

;;; Tables

(define asked (select open-shop (list 'tables-section "shop")))

(check-equal? "tables: opening the section the first time asks the database"
              (list (cadr asked) (list-ref (texts (car asked)) 4) (list-ref (texts (car asked)) 5))
              (list (list 'load-tables "shop") "  ▾ Tables" "      loading…"))

(define loaded
  (with-helpers (with-tables (car asked) "shop" (list "books" "audit.events")) "shop" (list "List" "Columns")))

(check-equal? "tables: the answer is listed, with a count"
              (list-tail (texts loaded) 4)
              (list "  ▾ Tables (2)" "    ▸ books" "    ▸ audit.events" "▸ current database"))

(check-equal? "tables: closing and reopening doesn't ask again"
              (let* ([closed (after-select loaded (list 'tables-section "shop"))]
                     [reopened (select closed (list 'tables-section "shop"))])
                (list (cadr reopened) (texts (car reopened))))
              (list (list 'none) (texts loaded)))

(check-equal? "tables: a table opens to its helpers"
              (list-tail (texts (after-select loaded (list 'table "shop" "books"))) 5)
              (list "    ▾ books" "        List" "        Columns" "    ▸ audit.events" "▸ current database"))

(check-equal? "tables: a failure is shown in the list's place, and no tables"
              (list-tail (texts (with-tables (car asked) "shop" (list 'failed "no such host"))) 4)
              (list "  ▾ Tables" "      no such host" "▸ current database"))

(check-equal? "tables: none"
              (list-ref (texts (with-tables (car asked) "shop" '())) 5)
              "      (no tables)")

(check-equal? "tables: one database's tables are not another's"
              (texts (after-select (after-select loaded (list 'entry "current database"))
                                   (list 'saved-section "current database")))
              (append (list-tail (reverse (list-tail (reverse (texts loaded)) 1)) 0)
                      (list "▾ current database"
                            "    + New query"
                            "  ▾ Saved queries (0)"
                            "      (none)"
                            "  ▸ Tables")))

(check-equal? "tables: forgetting a database asks for its tables anew"
              (let ([forgotten (after-select (forget-database loaded "shop") (list 'tables-section "shop"))])
                (action-of forgotten (list 'tables-section "shop")))
              (list 'load-tables "shop"))

;;; What a selection asks for

(check-equal? "select: what each kind of line does"
              (map (lambda (node) (action-of loaded node))
                   (list (list 'title)
                         (list 'entry "shop")
                         (list 'new-query "shop")
                         (list 'saved "shop" "big.sql")
                         (list 'table "shop" "books")
                         (list 'helper "shop" "books" "Columns")
                         (list 'note "shop")))
              (list (list 'none)
                    (list 'none)
                    (list 'new-query "shop")
                    (list 'open-saved "shop" "big.sql")
                    (list 'none)
                    (list 'run-helper "shop" "books" "Columns")
                    (list 'none)))

;;; Lines and nodes

(check-equal? "node: the node of a line, and (title) past either end"
              (map (lambda (index) (node-at (drawer-lines loaded) index)) (list 0 1 2 5 99 -1))
              (list (list 'title)
                    (list 'entry "shop")
                    (list 'new-query "shop")
                    (list 'table "shop" "books")
                    (list 'title)
                    (list 'title)))

(check-equal? "node: the line of a node, or #f"
              (list (line-of-node (drawer-lines loaded) (list 'table "shop" "audit.events"))
                    (line-of-node (drawer-lines loaded) (list 'table "shop" "nope")))
              (list 6 #f))

(check-equal? "tables: names out of a client's output"
              (parse-table-list "books\n audit.events \n\n")
              (list "books" "audit.events"))

;;; The store

(check-equal? "store: a label as a folder name"
              (map folder-name (list "shop" "current database" "postgres://app@host/db" ".." ""))
              (list "shop" "current_database" "postgres___app_host_db" "_.." "_"))

(check-equal? "store: which files are dadbod-ui's, and whose"
              (let ([file (string-append (entry-dir "shop") "/helpers/books.List.sql")])
                (list (query-file? file)
                      (label-of-file file)
                      (query-file? "/tmp/other.sql")
                      (query-file? (string-append (entry-dir "shop") "/notes.txt"))
                      (query-file? #f)))
              (list #t "shop" #f #f #f))

(check-equal? "store: options have defaults and can be set; unknown ones are refused"
              (list (option 'execute-on-save)
                    (option 'run-helpers)
                    (begin
                      (set-option! 'execute-on-save #t)
                      (option 'execute-on-save))
                    (error-message (lambda () (set-option! 'nope 1))))
              (list #f #t #t "dadbod-ui has no option called nope"))

(finish-tests!)
