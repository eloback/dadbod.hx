;; The editor, as dadbod needs it.
;;
;; This is the only file of the plugin that requires Helix's Steel modules
;; (tests/lint.sh checks). The plugin API lives in an unmerged fork and
;; changes; when it does, this file is where the change lands. What was
;; learned about that API the hard way is in docs/HELIX-API.md.

(require "helix/editor.scm")
(require "helix/misc.scm")
(require "helix/static.scm")
(require "helix/ext.scm")
(require "helix/keymaps.scm")
(require (prefix-in helix. "helix/commands.scm"))
(require-builtin helix/core/text as text.)

(provide status!
         error-status!
         selection-text
         buffer-text
         focused-path
         buffer-key
         workspace-dir
         set-extension-keys!
         run-when-not-typing!
         run-later!
         show-in-split!
         spawn-worker
         on-main-thread)

;;; The status line

(define (status! text)
  (set-status! text))

(define (error-status! text)
  (set-error! text))

;;; The focused buffer

(define (focused-doc)
  (editor->doc-id (editor-focus)))

;; The text of the primary selection. In normal mode there always is one:
;; the cursor is a selection one character wide.
(define (selection-text)
  (current-highlighted-text!))

(define (buffer-text)
  (text.rope->string (editor->text (focused-doc))))

;; The focused buffer's file, or #f for a scratch buffer.
(define (focused-path)
  (define path (editor-document->path (focused-doc)))
  (and (string? path) path))

;; What a choice made for the focused buffer is kept under: its file's
;; path, or for a scratch buffer its number in this session.
(define (buffer-key)
  (or (focused-path)
      (string-append "scratch:" (number->string (doc-id->usize (focused-doc))))))

;; The directory Helix was started in: the project.
(define (workspace-dir)
  (get-helix-cwd))

;;; Keys

;; Gives files with the extension `extension` (no dot) keys of their own in
;; normal mode, on top of the usual ones. `keys` is a hash from a key
;; ("R", "C-c") to what it does (":db-rerun").
(define (set-extension-keys! extension keys)
  (set-global-buffer-or-extension-keymap
   (hash extension (merge-keybindings (deep-copy-global-keybindings) (hash "normal" keys)))))

;;; Modes

(define (insert-mode?)
  (equal? (editor-mode) (string->editor-mode "insert")))

;; Calls `thunk` now unless Helix is in insert mode, and otherwise once it
;; has left it. Returns whether it ran now.
;;
;; For anything that moves the focus: doing that puts Helix in normal mode,
;; so in insert mode it would end the mode under the user's fingers and the
;; keys that follow would run as commands. In select mode it is fine: the
;; selection stays, and the user is not typing text. (Waiting there would
;; also wait forever: a selection made with `v` and run with :db-run leaves
;; Helix in select mode until the user does something about it.)
(define (run-when-not-typing! thunk)
  (cond
    [(not (insert-mode?))
     (thunk)
     #t]
    [else
     (enqueue-thread-local-callback-with-delay 150 (lambda () (run-when-not-typing! thunk)))
     #f]))

;; Calls `thunk` on the main thread in `ms` milliseconds.
(define (run-later! ms thunk)
  (enqueue-thread-local-callback-with-delay ms thunk))

;;; Windows

;; Shows the file at `path` in a horizontal split and puts its cursor on the
;; first line, leaving the focus where it was. `doc` is the document that
;; showed it last time, or #f: its window is reused when it is still open,
;; and it is reloaded, since the file changed under it. Returns the document
;; now showing the file.
;;
;; Not in insert mode: see run-when-not-typing!.
(define (show-in-split! path doc)
  (define origin (editor-focus))
  (define view (and doc (editor-doc-exists? doc) (editor-doc-in-view? doc)))
  (define shown
    (with-handler (lambda (err)
                    (set-error! (string-append "could not show " path ": " (trim (error-object-message err))))
                    doc)
                  (begin
                    (if view
                        (editor-set-focus! view)
                        (helix.hsplit path))
                    (let ([now-showing (focused-doc)])
                      (editor-document-reload now-showing)
                      (helix.goto-line 1)
                      now-showing))))
  (editor-set-focus! origin)
  shown)

;;; Threads

;; Runs `thunk` on a thread of its own. It has no access to the editor
;; there: it gets back through on-main-thread.
(define (spawn-worker thunk)
  (spawn-native-thread thunk))

;; From a worker thread: runs `thunk` on the main thread, where the editor
;; can be used. Doesn't wait for it.
(define (on-main-thread thunk)
  (hx.with-context thunk))
