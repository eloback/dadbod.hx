;; The editor, as dadbod-ui needs it: a panel (a buffer the plugin draws
;; into, with keys of its own), files, a prompt, hooks.
;;
;; The only file of dadbod-ui that requires Helix's Steel modules
;; (tests/lint.sh checks). See docs/HELIX-API.md.

(require "helix/editor.scm")
(require "helix/misc.scm")
(require "helix/static.scm")
(require "helix/keymaps.scm")
(require (prefix-in helix. "helix/commands.scm"))
(require-builtin helix/core/text as text.)

(provide status!
         error-status!
         focused-doc
         doc-open?
         normal-mode?
         open-panel!
         show-doc!
         set-panel-text!
         cursor-line
         open-file!
         close-focused-buffer!
         set-panel-keys!
         ask!
         on-file-saved!)

(define (status! text)
  (set-status! text))

(define (error-status! text)
  (set-error! text))

(define (focused-doc)
  (editor->doc-id (editor-focus)))

(define (doc-open? doc)
  (and doc (editor-doc-exists? doc)))

(define (normal-mode?)
  (equal? (editor-mode) (string->editor-mode "normal")))

;;; The panel

;; Opens a new scratch buffer in the focused window, called `name`, whose
;; keys are those set for `name` with set-panel-keys!. Returns its document.
(define (open-panel! name)
  (helix.new)
  (let ([doc (focused-doc)])
    (set-scratch-buffer-name! name)
    (*reverse-buffer-map-insert* (doc-id->usize doc) name)
    doc))

;; Shows an open document in the focused window.
(define (show-doc! doc)
  (editor-switch-action! doc (Action/Replace)))

;; Replaces the text of the focused buffer (the panel) and puts the cursor
;; on `line` (from 0). Only in normal mode.
(define (set-panel-text! text line)
  (select_all)
  (replace-selection-with text)
  (collapse_selection)
  (helix.goto-line (+ line 1))
  ;; Helix doesn't scroll to the cursor by itself when this runs from a
  ;; callback (a prompt's answer, a query's result).
  (align_view_center))

;; The line the cursor is on, from 0.
(define (cursor-line)
  (get-current-line-number))

;; Gives the panel called `name` keys of its own in normal mode, on top of
;; the usual ones. `keys` is a hash from a key ("ret", "R") to what it does
;; (":dbui-select").
(define (set-panel-keys! name keys)
  (set-global-buffer-or-extension-keymap
   (hash name (merge-keybindings (deep-copy-global-keybindings) (hash "normal" keys)))))

;;; Files and buffers

(define (open-file! path)
  (helix.open path))

;; Closes the focused buffer, whatever is in it.
(define (close-focused-buffer!)
  (helix.buffer-close!))

;;; Asking

;; Asks for a line of text at the bottom of the screen; `answer` gets it
;; when the user confirms. What is typed is visible.
(define (ask! label answer)
  (push-component! (prompt label answer)))

;;; Hooks

(define (with-path doc callback)
  (define path (editor-document->path doc))
  (when (string? path)
    (callback path)))

;; `callback` is called with the path and the text of every file that is
;; saved. The text is the buffer's: the hook can run before the file on disk
;; has it.
(define (on-file-saved! callback)
  (register-hook 'document-saved
                 (lambda (doc)
                   (with-path doc
                              (lambda (path) (callback path (text.rope->string (editor->text doc))))))))
