;; dadbod-ui: a drawer of your databases for dadbod.hx, in the manner of
;; vim-dadbod-ui: connections, their tables, ready-made queries about a
;; table, and saved queries.
;;
;;   (require "dadbod/dadbod.scm")
;;   (require "dadbod/dadbod-ui.scm")      in init.scm, then  :dbui
;;
;; This file is the plugin's entry point and nothing else: everything it
;; provides becomes a typed command in Helix. Options are set through
;; dadbod-ui/config.scm. See docs/DESIGN.md.

(require "dadbod-ui/hx/drawer.scm")

(provide dbui
         dbui-select
         dbui-refresh
         dbui-add
         dbui-delete
         dbui-help
         dbui-close)

;;@doc
;; Open the drawer of databases in this window.
;;
;; In the drawer: ret opens or closes what is under the cursor, or runs a
;; table's helper; R asks for the tables again; A adds a connection;
;; d deletes a saved query; q closes the drawer; ? shows the keys.
(define (dbui)
  (open-command!)
  void)

;;@doc
;; In the drawer: open or close what is under the cursor (ret).
(define (dbui-select)
  (select-command!)
  void)

;;@doc
;; In the drawer: ask the database under the cursor for its tables again (R).
(define (dbui-refresh)
  (refresh-command!)
  void)

;;@doc
;; In the drawer: add a connection to your connections file (A).
(define (dbui-add)
  (add-command!)
  void)

;;@doc
;; In the drawer: delete the saved query under the cursor (d).
(define (dbui-delete)
  (delete-command!)
  void)

;;@doc
;; In the drawer: show or hide the keys (?).
(define (dbui-help)
  (help-command!)
  void)

;;@doc
;; In the drawer: close it (q).
(define (dbui-close)
  (close-command!)
  void)
