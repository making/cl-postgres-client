;;;; src/execute.lisp
;;;;
;;;; Where a statement finally runs: the terminal operations of the fluent
;;;; builder, the one-line forms, and the streaming forms.
;;;;
;;;; The one-line forms are compositions of the fluent ones rather than a second
;;;; implementation, so there is exactly one code path from SQL text to result
;;;; and the two styles can never drift apart.
;;;;
;;;; Cardinality is decided here and shape is decided by :AS, which is the split
;;;; JdbcClient makes too: query(...) chooses the mapping, list/single/optional
;;;; choose how many rows the caller will stand for.

(in-package #:postgres-client)

(defun coerce-result-spec (object &optional format)
  "Return OBJECT as a result spec, overriding its row format with FORMAT when
one is given. Accepting a bare statement is what lets VALUE or SINGLE follow
PARAM directly, without an intervening QUERY."
  (etypecase object
    (result-spec (if format
                     (%make-result-spec :statement (result-spec-statement object)
                                        :format format)
                     object))
    (statement (%make-result-spec :statement object
                                  :format (or format *default-row-format*)))))

(defun query (statement &key (as *default-row-format*))
  "Say that STATEMENT is to be read as rows in the AS format, and return a
result spec for ROWS, SINGLE, OPTIONAL, VALUE or COLUMN to execute.
See ROW-MAPPER for the formats AS accepts."
  (%make-result-spec :statement (result-spec-statement (coerce-result-spec statement))
                     :format as))

(defun rows (result)
  "Execute RESULT and return all of its rows as a list."
  (let* ((spec (coerce-result-spec result))
         (statement (result-spec-statement spec)))
    (execute-statement statement
                       (make-collecting-row-reader (result-spec-format spec)
                                                   (statement-sql statement)))))

(defun single (result)
  "Execute RESULT and return its one row.
Signals EMPTY-RESULT-ERROR when there is none and TOO-MANY-ROWS-ERROR when
there is more than one."
  (let* ((spec (coerce-result-spec result))
         (sql (statement-sql (result-spec-statement spec)))
         (result-rows (rows spec)))
    (cond ((null result-rows) (error 'empty-result-error :sql sql))
          ((rest result-rows) (error 'too-many-rows-error
                                     :sql sql
                                     :row-count (length result-rows)))
          (t (first result-rows)))))

(defun optional (result)
  "Execute RESULT and return its one row, or NIL when there is none.
Signals TOO-MANY-ROWS-ERROR when there is more than one."
  (let* ((spec (coerce-result-spec result))
         (sql (statement-sql (result-spec-statement spec)))
         (result-rows (rows spec)))
    (cond ((null result-rows) nil)
          ((rest result-rows) (error 'too-many-rows-error
                                     :sql sql
                                     :row-count (length result-rows)))
          (t (first result-rows)))))

(defun value (result)
  "Execute RESULT and return the single value of its single row.
The row format is forced to :VALUE, so this reads the same whether or not QUERY
was given an :AS. Signals TOO-MANY-COLUMNS-ERROR when several columns are
selected, and EMPTY-RESULT-ERROR when no row comes back."
  (single (coerce-result-spec result :value)))

(defun column (result)
  "Execute RESULT and return its first column as a list, one element per row.
Signals TOO-MANY-COLUMNS-ERROR when several columns are selected."
  (rows (coerce-result-spec result :value)))

(defun execute (client sql)
  "Run SQL on CLIENT with no parameters, returning the number of rows affected
or NIL for a statement that reports none.
This uses the simple query protocol, so it also carries the utility commands --
BEGIN, SET, VACUUM, most of DDL -- that cannot be sent as prepared statements."
  (nth-value 1 (cl-postgres:exec-query (%client-connection client) sql
                                       'cl-postgres:ignore-row-reader)))

;;; ---------------------------------------------------------------------
;;; One-line forms
;;; ---------------------------------------------------------------------

(defun build-statement (client sql parameters)
  "Return a statement for SQL on CLIENT with PARAMETERS bound."
  (let ((statement (sql client sql)))
    (if parameters
        (params statement parameters)
        statement)))

(defun query-list (client sql &key params (as *default-row-format*))
  "Run SQL on CLIENT and return all rows.

    (pgc:query-list client \"select id, name from users where age > :age\"
                    :params '(:age 20))
    ;=> ((:id 1 :name \"alice\") (:id 2 :name \"bob\"))"
  (rows (query (build-statement client sql params) :as as)))

(defun query-single (client sql &key params (as *default-row-format*))
  "Run SQL on CLIENT and return its one row.
Signals EMPTY-RESULT-ERROR or TOO-MANY-ROWS-ERROR when there is not exactly one."
  (single (query (build-statement client sql params) :as as)))

(defun query-optional (client sql &key params (as *default-row-format*))
  "Run SQL on CLIENT and return its one row, or NIL when there is none.
Signals TOO-MANY-ROWS-ERROR when there is more than one."
  (optional (query (build-statement client sql params) :as as)))

(defun query-value (client sql &key params)
  "Run SQL on CLIENT and return the single value of its single row.

    (pgc:query-value client \"select count(*) from users\") ;=> 42"
  (value (query (build-statement client sql params) :as :value)))

(defun query-column (client sql &key params)
  "Run SQL on CLIENT and return its first column as a list, one element per row."
  (column (query (build-statement client sql params) :as :value)))

(defun update (target &rest arguments)
  "Execute a modifying statement and return the number of rows it affected.

Given a client this is the one-line form:

    (pgc:update client \"insert into users (name) values (:name)\"
                :params '(:name \"bob\")) ;=> 1

Given a statement it is the terminal operation of the fluent form:

    (pgc:-> (pgc:sql client \"insert into users (name) values (:name)\")
            (pgc:param :name \"bob\")
            (pgc:update))

Use QUERY when the statement has a RETURNING clause whose rows you want."
  (let ((statement (etypecase target
                     (client (destructuring-bind (sql &key params) arguments
                               (build-statement target sql params)))
                     ((or statement result-spec)
                      (when arguments
                        (error "UPDATE of an already built statement takes no
further arguments, but got ~s." arguments))
                      (if (result-spec-p target)
                          (result-spec-statement target)
                          target)))))
    (nth-value 1 (execute-statement statement 'cl-postgres:ignore-row-reader))))

(defun batch-update (client sql parameter-sets)
  "Run SQL on CLIENT once for each entry of PARAMETER-SETS, returning the list
of affected row counts. The statement is prepared once and reused.

    (pgc:batch-update client \"insert into users (name) values (:name)\"
                      '((:name \"alice\") (:name \"bob\"))) ;=> (1 1)"
  (let ((base (sql client sql)))
    (mapcar (lambda (parameters) (update (params base parameters))) parameter-sets)))

;;; ---------------------------------------------------------------------
;;; Streaming
;;; ---------------------------------------------------------------------

(defun map-rows (function client sql &key params (as *default-row-format*))
  "Call FUNCTION with each row of SQL's result in turn, returning how many rows
were read. Rows are handed over as they arrive, so the whole result never has to
fit in memory."
  (let ((statement (build-statement client sql params)))
    (execute-statement statement (make-streaming-row-reader as sql function))))

(defun fold-rows (function initial client sql &key params (as *default-row-format*))
  "Reduce SQL's result into an accumulator, starting from INITIAL.
FUNCTION is called with the accumulator and each row, and returns the next
accumulator. Like MAP-ROWS, this never holds the whole result.

    (pgc:fold-rows #'+ 0 client \"select amount from orders\" :as :value)"
  (let ((accumulator initial))
    (map-rows (lambda (row) (setf accumulator (funcall function accumulator row)))
              client sql :params params :as as)
    accumulator))

(defmacro do-rows ((row client sql &key params (as nil as-supplied-p)) &body body)
  "Evaluate BODY with ROW bound to each row of SQL's result in turn.
Rows arrive one at a time, so this is the form to reach for when the result is
too large to collect. RETURN leaves the loop early and the rest of the result is
drained, so the connection stays usable.

    (pgc:do-rows (row client \"select id, name from users\")
      (format t \"~a~%\" (getf row :name)))"
  `(block nil
     (map-rows (lambda (,row) ,@body)
               ,client ,sql
               :params ,params
               ,@(when as-supplied-p `(:as ,as)))))
