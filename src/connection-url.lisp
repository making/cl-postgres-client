;;;; src/connection-url.lisp
;;;;
;;;; Connection URLs -- postgresql://user:password@host:port/database?parameters
;;;; -- taken apart into the keyword arguments CONNECT accepts.
;;;;
;;;; Everything that hands out PostgreSQL credentials hands them out as one
;;;; string: DATABASE_URL in a twelve-factor app, and whatever Heroku, Fly,
;;;; Supabase, Docker Compose or a Kubernetes secret puts in it.  That is the
;;;; form a caller has, so it is the form this library should be able to read.
;;;;
;;;; It is written out by hand rather than reached for from a URI library
;;;; because cl-postgres is the only runtime dependency this library is willing
;;;; to have.  What earns the file is not the splitting but what surrounds it:
;;;; an @ inside a percent-encoded password, where a naive scan finds the wrong
;;;; one; the colons of an IPv6 literal, which are not the port separator; and
;;;; libpq's six sslmode values, which do not line up one for one with
;;;; cl-postgres's five USE-SSL values.
;;;;
;;;; The order matters throughout: split first, decode after.  A percent escape
;;;; that decodes into a delimiter is data, not a delimiter, and decoding early
;;;; is exactly how that distinction gets lost.

(in-package #:postgres-client)

;;; ---------------------------------------------------------------------
;;; Percent-encoding
;;; ---------------------------------------------------------------------

(defun percent-escape-byte (text index url)
  "Return the byte the %XX escape at INDEX in TEXT stands for."
  (let* ((in-bounds (< (+ index 2) (length text)))
         (high (when in-bounds (digit-char-p (char text (1+ index)) 16)))
         (low (when in-bounds (digit-char-p (char text (+ index 2)) 16))))
    (unless (and high low)
      (%connection-url-error url "A % is not followed by two hexadecimal digits"))
    (+ (* 16 high) low)))

(defun utf-8-leader (byte url)
  "Return how many continuation bytes follow the leading UTF-8 byte BYTE, and
the bits BYTE itself contributes to the code point."
  (cond ((< byte #x80) (values 0 byte))
        ((= (logand byte #xe0) #xc0) (values 1 (logand byte #x1f)))
        ((= (logand byte #xf0) #xe0) (values 2 (logand byte #x0f)))
        ((= (logand byte #xf8) #xf0) (values 3 (logand byte #x07)))
        (t (%connection-url-error url "A percent-encoded byte begins no character"))))

(defun decode-percent-encoding (text url)
  "Return TEXT with its %XX escapes decoded.
The decoded bytes are read as UTF-8, so %C3%A9 is one character rather than two.
A character that was never escaped is left exactly as it is."
  (if (null (position #\% text))
      text
      (let ((length (length text))
            (index 0))
        (with-output-to-string (out)
          (loop :while (< index length)
                :do (let ((char (char text index)))
                      (if (char/= char #\%)
                          (progn (write-char char out)
                                 (incf index))
                          (multiple-value-bind (continuations code)
                              (utf-8-leader (percent-escape-byte text index url) url)
                            (incf index 3)
                            (loop :repeat continuations
                                  :do (unless (and (< index length)
                                                   (char= (char text index) #\%))
                                        (%connection-url-error
                                         url "A percent-encoded character stops short"))
                                      (let ((byte (percent-escape-byte text index url)))
                                        (unless (= (logand byte #xc0) #x80)
                                          (%connection-url-error
                                           url "A percent-encoded character stops short"))
                                        (setf code (+ (* 64 code) (logand byte #x3f)))
                                        (incf index 3)))
                            (write-char (code-char code) out)))))))))

;;; ---------------------------------------------------------------------
;;; Splitting
;;; ---------------------------------------------------------------------

(defun connection-url-body-start (url)
  "Return the index just past URL's scheme, or NIL when URL carries neither the
postgresql:// nor the postgres:// scheme."
  (let ((separator (search "://" url)))
    (when separator
      (let ((scheme (subseq url 0 separator)))
        (when (or (string-equal scheme "postgresql")
                  (string-equal scheme "postgres"))
          (+ separator 3))))))

(defun split-fields (character text)
  "Return TEXT's non-empty fields, split on CHARACTER."
  (let ((length (length text))
        (fields '())
        (start 0))
    (loop :while (<= start length)
          :do (let ((separator (or (position character text :start start) length)))
                (when (> separator start)
                  (push (subseq text start separator) fields))
                (setf start (1+ separator))))
    (nreverse fields)))

(defun split-authority (authority url)
  "Return the user, the password and the host-and-port AUTHORITY holds.
The at-sign taken as the delimiter is the LAST one, and the colon inside the
user information the FIRST, because a password holding either character
percent-encodes it and would otherwise be read as the delimiter itself."
  (let ((at (position #\@ authority :from-end t)))
    (if (null at)
        (values nil nil authority)
        (let* ((user-information (subseq authority 0 at))
               (colon (position #\: user-information))
               (user (decode-percent-encoding
                      (subseq user-information 0 (or colon (length user-information)))
                      url)))
          (values (unless (string= user "") user)
                  (when colon
                    (decode-percent-encoding (subseq user-information (1+ colon)) url))
                  (subseq authority (1+ at)))))))

(defun parse-url-port (digits url)
  "Return the port number DIGITS spells."
  (unless (and (plusp (length digits)) (every #'digit-char-p digits))
    (%connection-url-error url "The port is not a number"))
  (parse-integer digits))

(defun split-host-and-port (host-and-port url)
  "Return the host and the port HOST-AND-PORT holds, either being NIL when it is
absent. A bracketed IPv6 literal keeps its own colons: only a colon after the
closing bracket introduces the port."
  (let* ((bracketed (and (plusp (length host-and-port))
                         (char= (char host-and-port 0) #\[)))
         (bracket (when bracketed (position #\] host-and-port))))
    (when (and bracketed (null bracket))
      (%connection-url-error url "An IPv6 literal is missing its closing bracket"))
    (let* ((host-end (if bracketed
                         (1+ bracket)
                         (or (position #\: host-and-port) (length host-and-port))))
           (host (if bracketed
                     (subseq host-and-port 1 bracket)
                     (decode-percent-encoding (subseq host-and-port 0 host-end) url)))
           (tail (subseq host-and-port host-end)))
      (when (and (plusp (length tail)) (char/= (char tail 0) #\:))
        (%connection-url-error url "Expected a port after the host"))
      (values (unless (string= host "") host)
              (unless (string= tail "") (parse-url-port (subseq tail 1) url))))))

;;; ---------------------------------------------------------------------
;;; Query parameters
;;; ---------------------------------------------------------------------

(defun connection-url-ssl-mode (value url)
  "Return the USE-SSL value libpq's sslmode VALUE asks for.
ALLOW and PREFER both land on :TRY, which is the one cl-postgres has: it offers
SSL and accepts a plain connection when the server declines."
  (cond ((string-equal value "disable") :no)
        ((string-equal value "allow") :try)
        ((string-equal value "prefer") :try)
        ((string-equal value "require") :require)
        ((string-equal value "verify-ca") :yes)
        ((string-equal value "verify-full") :full)
        (t (%connection-url-error url (format nil "~s is not an sslmode" value)))))

(defun connection-url-parameter (name value url)
  "Return the CONNECT argument the query parameter NAME=VALUE stands for, as the
two-element list a plist is built from."
  (cond ((string-equal name "sslmode")
         (list :use-ssl (connection-url-ssl-mode value url)))
        ((string-equal name "application_name")
         (list :application-name value))
        ((string-equal name "dbname")
         (list :database value))
        ((string-equal name "user")
         (list :user value))
        ((string-equal name "password")
         (list :password value))
        ((string-equal name "host")
         ;; A path rather than a name is libpq's way of asking for the Unix
         ;; domain socket. cl-postgres takes the directory from a variable of
         ;; its own, so only the request itself carries over.
         (list :host (if (and (plusp (length value)) (char= (char value 0) #\/))
                         :unix
                         value)))
        ((string-equal name "port")
         (list :port (parse-url-port value url)))
        (t (%connection-url-error
            url (format nil "~s is not a connection parameter this library reads" name)))))

(defun parse-connection-url-query (query url)
  "Return the CONNECT arguments the query string QUERY stands for, as a plist."
  (loop :for field :in (split-fields #\& query)
        :append (let* ((equals (position #\= field))
                       (name (decode-percent-encoding
                              (subseq field 0 (or equals (length field))) url))
                       (value (if equals
                                  (decode-percent-encoding (subseq field (1+ equals)) url)
                                  "")))
                  (connection-url-parameter name value url))))

;;; ---------------------------------------------------------------------
;;; The whole URL
;;; ---------------------------------------------------------------------

(defun parse-connection-url (url)
  "Take the connection URL URL apart into the keyword arguments CONNECT accepts.

    (pgc:parse-connection-url
     \"postgresql://app:secret@db.internal:5432/app?sslmode=require\")
    ;; => (:DATABASE \"app\" :USER \"app\" :HOST \"db.internal\" :PORT 5432
    ;;     :PASSWORD \"secret\" :USE-SSL :REQUIRE)

so that (APPLY #'CONNECT (PARSE-CONNECTION-URL url)) is what (CONNECT :URL url)
does. Use it directly when the pieces are wanted for something else -- logging
the host without the password, say.

Both the postgresql:// and the postgres:// scheme are read, and every component
is optional: only what the URL actually mentions appears in the plist, so a URL
naming no database leaves CONNECT to insist on one as it always does.
Percent escapes are decoded, as UTF-8, only after the URL has been split, so a
password may hold an @ or a : of its own; an IPv6 literal in brackets keeps its
colons.

The query parameters read are sslmode, application_name, host, port, dbname,
user and password. Any other is an error rather than something silently
dropped, and a parameter takes precedence over the same component spelled out in
the URL itself. sslmode maps onto USE-SSL as disable to :NO, allow and prefer to
:TRY, require to :REQUIRE, verify-ca to :YES and verify-full to :FULL. A host
parameter beginning with / asks for a Unix domain socket, which this library
spells :UNIX.

Signals CONNECTION-URL-ERROR when URL is not a connection URL, or when one of
its parts is malformed."
  (check-type url string)
  (let ((start (connection-url-body-start url)))
    (unless start
      (%connection-url-error url "Expected a postgresql:// or a postgres:// URL"))
    (let* ((query-start (position #\? url :start start))
           (body-end (or query-start (length url)))
           (path-start (position #\/ url :start start :end body-end))
           (authority (subseq url start (or path-start body-end)))
           (path (if path-start (subseq url (1+ path-start) body-end) ""))
           (options (parse-connection-url-query
                     (if query-start (subseq url (1+ query-start)) "") url)))
      (multiple-value-bind (user password host-and-port) (split-authority authority url)
        (multiple-value-bind (host port) (split-host-and-port host-and-port url)
          ;; Pushed in reverse so the plist reads in the order the URL spells
          ;; its components, and skipped where the query already gave one, so
          ;; that no key appears twice.
          (flet ((add (key value)
                   (when (and value (null (getf options key)))
                     (setf options (list* key value options)))))
            (add :password password)
            (add :port port)
            (add :host host)
            (add :user user)
            (add :database (unless (string= path "")
                             (decode-percent-encoding path url))))
          options)))))
