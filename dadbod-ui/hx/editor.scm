;; The editor, as dadbod-ui needs it: a floating list over the editor (like
;; Helix's own pickers), files, a prompt, a hook.
;;
;; The only file of dadbod-ui that requires Helix's Steel modules
;; (tests/lint.sh checks). See docs/HELIX-API.md.

(require "helix/editor.scm")
(require "helix/misc.scm")
(require (prefix-in helix. "helix/commands.scm"))
(require-builtin helix/core/text as text.)
(require-builtin helix/components)

(provide status!
         error-status!
         open-float!
         close-float!
         open-file!
         ask!
         on-file-saved!)

(define (status! text)
  (set-status! text))

(define (error-status! text)
  (set-error! text))

;;; The floating list
;;
;; A box in the middle of the screen with a title, lines of text, one of
;; them marked as the cursor's, and a footer. While it is open it gets every
;; key. The plugin keeps what is in it: the box asks each time it is drawn.

(define (spaces n)
  (list->string (map (lambda (_) #\space) (range 0 (max 0 n)))))

;; `text` cut or padded to exactly `width` characters.
(define (fitted text width)
  (define len (string-length text))
  (if (>= len width)
      (substring text 0 width)
      (string-append text (spaces (- width len)))))

;; The first line to show so that line `cursor` is among `rows` lines.
(define (scroll-offset cursor rows)
  (max 0 (- cursor (- rows 1))))

;; view: () -> (list title lines cursor footer)
;;   title, footer   text for the box's top and bottom edge
;;   lines           the lines, as strings
;;   cursor          the index of the cursor's line
(define (draw-float view rect frame)
  (define shown (view))
  (define title (car shown))
  (define lines (cadr shown))
  (define cursor (caddr shown))
  (define footer (cadddr shown))
  (define width (max 20 (min 90 (- (area-width rect) 4))))
  (define height (max 3 (min (+ (length lines) 2) (- (area-height rect) 4))))
  (define x (+ (area-x rect) (quotient (- (area-width rect) width) 2)))
  (define y (+ (area-y rect) (quotient (- (area-height rect) height) 2)))
  (define box (area x y width height))
  (define text-style (theme-scope *helix.cx* "ui.text"))
  (define selected-style (theme-scope *helix.cx* "ui.menu.selected"))
  (define rows (- height 2))
  (define offset (scroll-offset cursor rows))
  (buffer/clear frame box)
  (block/render frame box (make-block (theme-scope *helix.cx* "ui.popup") text-style "all" "rounded"))
  (frame-set-string! frame (+ x 2) y (string-append " " title " ") text-style)
  (let loop ([row 0] [rest (if (> offset 0) (list-tail lines (min offset (length lines))) lines)])
    (when (and (< row rows) (not (null? rest)))
      (frame-set-string! frame
                         (+ x 1)
                         (+ y 1 row)
                         (fitted (car rest) (- width 2))
                         (if (= (+ row offset) cursor) selected-style text-style))
      (loop (+ row 1) (cdr rest))))
  (frame-set-string! frame
                     (+ x 2)
                     (+ y height -1)
                     (fitted (string-append " " footer " ") (min (- width 4) (+ (string-length footer) 2)))
                     text-style))

;; A key as text: a character ("j", "R", "?"), or "ret", "esc", "up",
;; "down", "tab", "backspace". #f for anything else (the mouse, a resize).
(define (key-name event)
  (cond
    [(not (key-event? event)) #f]
    [(key-event-enter? event) "ret"]
    [(key-event-escape? event) "esc"]
    [(key-event-up? event) "up"]
    [(key-event-down? event) "down"]
    [(key-event-tab? event) "tab"]
    [(key-event-backspace? event) "backspace"]
    [(char? (key-event-char event)) (list->string (list (key-event-char event)))]
    [else #f]))

;; Opens the floating list called `name`.
;;   view     see draw-float
;;   on-key   (key) -> 'close to close the list, anything else to keep it.
;;            Called with each key pressed while it is open; errors it
;;            raises are shown in the status line.
(define (open-float! name view on-key)
  (push-component!
   (new-component! name
                   #f
                   (lambda (_ rect frame) (draw-float view rect frame))
                   (hash "handle_event"
                         (lambda (_ event)
                           (define key (key-name event))
                           (define answer
                             (and key
                                  (with-handler (lambda (err)
                                                  (set-error! (trim (error-object-message err)))
                                                  #f)
                                                (on-key key))))
                           (if (equal? answer 'close) event-result/close event-result/consume))))))

;; Closes the floating list called `name`, if it is open.
(define (close-float! name)
  (pop-last-component-by-name! name))

;;; Files

(define (open-file! path)
  (helix.open path))

;;; Asking

;; Asks for a line of text at the bottom of the screen; `answer` gets it
;; when the user confirms. What is typed is visible.
(define (ask! label answer)
  (push-component! (prompt label answer)))

;;; Hooks

;; `callback` is called with the path and the text of every file that is
;; saved. The text is the buffer's: the hook can run before the file on disk
;; has it.
(define (on-file-saved! callback)
  (register-hook 'document-saved
                 (lambda (doc)
                   (define path (editor-document->path doc))
                   (when (string? path)
                     (callback path (text.rope->string (editor->text doc)))))))
