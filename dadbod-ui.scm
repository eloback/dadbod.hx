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

(provide dbui)

;;@doc
;; Open the drawer of databases, floating over the editor.
;;
;; j and k move; ret opens or closes what is under the cursor, opens a
;; query, or runs a table's helper; R asks for the tables again; A adds a
;; connection; d deletes a saved query; ? shows the keys; q or esc closes.
(define (dbui)
  (open-command!)
  void)
