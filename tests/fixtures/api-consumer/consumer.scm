;; A second plugin, for tests/e2e/api.sh: it uses dadbod only through
;; dadbod/api.scm, from a directory of its own, the way dadbod-ui will.
;;
;; Its commands report in the status line, prefixed "consumer:".

(require "helix/misc.scm")
(require "../../../dadbod/api.scm")

(provide consumer-url
         consumer-use
         consumer-answer
         consumer-run)

(define (say . parts)
  (set-status! (apply string-append (cons "consumer: " parts))))

(define (first-line path)
  (define port (open-input-file path))
  (define text (read-port-to-string port))
  (close-input-port port)
  (car (split-many (string-append text "\n") "\n")))

;; Which database dadbod would run against, without the password.
(define (consumer-url)
  (define url (dadbod-current))
  (say "url=" (if url (dadbod-display url) "none"))
  void)

(define (consumer-use url-text)
  (with-handler (lambda (err) (say "refused: " (trim (error-object-message err))))
                (begin
                  (dadbod-use! url-text)
                  (say "using " (dadbod-display url-text))))
  void)

;; Asks the current database a question and reads the answer itself.
(define (consumer-answer . sql)
  (dadbod-query! (dadbod-current)
                 (if (null? sql) "select 40 + 2;" (string-join sql " "))
                 (lambda (failure stdout-file stderr-file)
                   (if failure
                       (say "failed: " failure " / " (first-line stderr-file))
                       (say "answer=" (first-line stdout-file)))))
  void)

;; Runs a query of its own through dadbod's result split.
(define (consumer-run)
  (dadbod-run! (dadbod-current) "select 'from the consumer' as origin;")
  void)
