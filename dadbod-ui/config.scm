;; dadbod-ui's options, for init.scm:
;;
;;   (require "dadbod/dadbod-ui/config.scm")
;;   (dadbod-ui-set! 'execute-on-save #t)
;;
;; This is a file of its own because whatever the entry file provides
;; becomes a typed command.
;;
;;   'execute-on-save   saving one of dadbod-ui's query files runs it
;;                      (default #f)
;;   'run-helpers       choosing a table's helper in the drawer runs it
;;                      right away (default #t); with #f it only opens the
;;                      query

(require "core/store.scm")

(provide dadbod-ui-set!)

(define (dadbod-ui-set! name value)
  (set-option! name value))
