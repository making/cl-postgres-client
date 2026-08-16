;;;; src/named-parameters.lisp
;;;;
;;;; SQL text handling: rewriting :NAME placeholders into PostgreSQL's $N, and
;;;; quoting identifiers.
;;;;
;;;; cl-postgres only speaks $1, $2, ..., so the whole of the named-parameter
;;;; feature lives in this one scanner.  It has to be a real scanner rather than
;;;; a search-and-replace, because a colon in PostgreSQL is overloaded: it
;;;; introduces a cast (id::integer), an assignment (:=) and an array slice
;;;; (a[1:3]), and it appears inside string literals, dollar-quoted bodies,
;;;; quoted identifiers and comments.  Every one of those must be left alone.
;;;;
;;;; Note that ? is deliberately NOT treated as a placeholder: in PostgreSQL it
;;;; is a jsonb and geometry operator (data ? 'key'), so rewriting it would
;;;; silently break valid SQL.  Use :NAME, or write $1 yourself.

(in-package #:postgres-client)

(declaim (inline identifier-start-p identifier-char-p))

(defun identifier-start-p (char)
  "True when CHAR may begin an unquoted SQL identifier."
  (and char (or (alpha-char-p char) (char= char #\_))))

(defun identifier-char-p (char)
  "True when CHAR may appear inside an unquoted SQL identifier."
  (and char (or (alphanumericp char) (char= char #\_))))

(defun normalize-parameter-name (name)
  "Normalize NAME -- a keyword, symbol or string -- to the keyword this library
uses to identify a parameter: upper case, with underscores read as hyphens.
:USER-ID, :|user_id| and \"user_id\" therefore all name the same parameter, so
SQL can stay snake_case while Lisp stays kebab-case."
  (let ((text (etypecase name
                (string name)
                (symbol (symbol-name name)))))
    (intern (substitute #\- #\_ (string-upcase text)) :keyword)))

(defun quote-identifier (name)
  "Return NAME as a double-quoted PostgreSQL identifier, doubling any embedded
double quote. Use this for table, column and channel names, which cannot be
passed as parameters."
  (let ((text (etypecase name
                (string name)
                (symbol (string-downcase (symbol-name name))))))
    (with-output-to-string (out)
      (write-char #\" out)
      (loop :for char :across text
            :do (when (char= char #\") (write-char #\" out))
                (write-char char out))
      (write-char #\" out))))

;;; ---------------------------------------------------------------------
;;; The scanner
;;; ---------------------------------------------------------------------

(defun scan-line-comment (sql start)
  "Return the index just past the -- comment beginning at START."
  (let ((newline (position #\Newline sql :start start)))
    (if newline (1+ newline) (length sql))))

(defun scan-block-comment (sql start)
  "Return the index just past the /* */ comment beginning at START.
PostgreSQL nests block comments, so this counts depth."
  (let ((length (length sql))
        (index (+ start 2))
        (depth 1))
    (loop :while (and (plusp depth) (< index length))
          :do (let ((char (char sql index))
                    (next (when (< (1+ index) length) (char sql (1+ index)))))
                (cond ((and (char= char #\/) (eql next #\*)) (incf depth) (incf index 2))
                      ((and (char= char #\*) (eql next #\/)) (decf depth) (incf index 2))
                      (t (incf index)))))
    index))

(defun escape-string-p (sql start)
  "True when the quote at START opens an E'...' escape string literal, in which
a backslash escapes the following character."
  (and (plusp start)
       (member (char sql (1- start)) '(#\e #\E))
       (or (= start 1)
           (not (identifier-char-p (char sql (- start 2)))))))

(defun scan-string-literal (sql start)
  "Return the index just past the single-quoted literal beginning at START."
  (let ((length (length sql))
        (escapes (escape-string-p sql start))
        (index (1+ start)))
    (loop :while (< index length)
          :do (let ((char (char sql index)))
                (cond ((and escapes (char= char #\\) (< (1+ index) length))
                       (incf index 2))
                      ((char= char #\')
                       (if (eql (when (< (1+ index) length) (char sql (1+ index))) #\')
                           (incf index 2)
                           (return-from scan-string-literal (1+ index))))
                      (t (incf index)))))
    length))

(defun scan-quoted-identifier (sql start)
  "Return the index just past the double-quoted identifier beginning at START."
  (let ((length (length sql))
        (index (1+ start)))
    (loop :while (< index length)
          :do (if (char= (char sql index) #\")
                  (if (eql (when (< (1+ index) length) (char sql (1+ index))) #\")
                      (incf index 2)
                      (return-from scan-quoted-identifier (1+ index)))
                  (incf index)))
    length))

(defun dollar-quote-tag-end (sql start)
  "When the $ at START opens a dollar-quoted string, return the index just past
its opening tag; otherwise NIL. $1 is a placeholder, not a tag, because a tag
cannot begin with a digit."
  (let ((length (length sql))
        (index (1+ start)))
    (when (and (< index length) (identifier-start-p (char sql index)))
      (loop :while (and (< index length) (identifier-char-p (char sql index)))
            :do (incf index)))
    (when (and (< index length) (char= (char sql index) #\$))
      (1+ index))))

(defun scan-dollar-quoted (sql start tag-end)
  "Return the index just past the dollar-quoted string that opens at START and
whose opening tag ends at TAG-END."
  (let* ((tag (subseq sql start tag-end))
         (closing (search tag sql :start2 tag-end)))
    (if closing (+ closing (length tag)) (length sql))))

(defun parse-named-parameters (sql)
  "Rewrite :NAME placeholders in SQL into PostgreSQL's positional $N placeholders.

Returns two values: the rewritten SQL, and the parameter names as normalized
keywords in $1 ... $N order. A name used more than once takes a single $N and
appears once in the list. When SQL holds no named placeholder it is returned
unchanged together with NIL, so statements written directly against $1, $2 ...
pass through untouched.

String literals (including E'...'), dollar-quoted strings, quoted identifiers,
line and block comments, ::casts, := assignment and array slices are skipped, so
a colon inside any of them is never mistaken for a parameter."
  (check-type sql string)
  (let ((length (length sql))
        (names (make-array 4 :adjustable t :fill-pointer 0))
        (index 0)
        (out (make-string-output-stream)))
    (flet ((copy-through (end)
             (write-string sql out :start index :end end)
             (setf index end))
           (placeholder-index (name)
             (let ((existing (position name names)))
               (1+ (or existing (vector-push-extend name names))))))
      (loop :while (< index length)
            :do (let ((char (char sql index))
                      (next (when (< (1+ index) length) (char sql (1+ index)))))
                  (cond
                    ((and (char= char #\-) (eql next #\-))
                     (copy-through (scan-line-comment sql index)))
                    ((and (char= char #\/) (eql next #\*))
                     (copy-through (scan-block-comment sql index)))
                    ((char= char #\')
                     (copy-through (scan-string-literal sql index)))
                    ((char= char #\")
                     (copy-through (scan-quoted-identifier sql index)))
                    ((char= char #\$)
                     (let ((tag-end (dollar-quote-tag-end sql index)))
                       (if tag-end
                           (copy-through (scan-dollar-quoted sql index tag-end))
                           (copy-through (1+ index)))))
                    ((and (char= char #\:) (member next '(#\: #\=)))
                     (copy-through (+ index 2)))
                    ((and (char= char #\:) (identifier-start-p next))
                     (let ((end (1+ index)))
                       (loop :while (and (< end length) (identifier-char-p (char sql end)))
                             :do (incf end))
                       (format out "$~d"
                               (placeholder-index
                                (normalize-parameter-name (subseq sql (1+ index) end))))
                       (setf index end)))
                    (t (copy-through (1+ index)))))))
    (if (zerop (fill-pointer names))
        (values sql nil)
        (values (get-output-stream-string out) (coerce names 'list)))))
