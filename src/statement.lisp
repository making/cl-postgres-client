;;;; src/statement.lisp
;;;;
;;;; The statement specification -- this library's answer to JdbcClient's
;;;; StatementSpec -- and the prepared-statement bookkeeping underneath it.
;;;;
;;;; A statement is immutable: PARAM and PARAMS return a copy.  That makes a
;;;; half-built statement safe to keep and finish several different ways, and it
;;;; is what lets -> read as a pipeline rather than as a sequence of mutations.
;;;;
;;;; cl-postgres has no "execute this SQL with these parameters" entry point --
;;;; parameters exist only for statements that were parsed under a name first.
;;;; Managing those names is therefore not an optimisation here, it is the only
;;;; way to pass a parameter at all.

(in-package #:postgres-client)

(defmacro -> (form &rest forms)
  "Thread FORM through FORMS, inserting it as each one's first argument.
A symbol stands for a call with no further arguments.

    (pgc:-> (pgc:sql client \"select age from customer where id = :id\")
            (pgc:param :id 3)
            (pgc:query :as :value)
            (pgc:optional))"
  (let ((result form))
    (dolist (next forms result)
      (setf result (if (consp next)
                       (list* (first next) result (rest next))
                       (list next result))))))

(defstruct (statement (:constructor %make-statement) (:copier %copy-statement))
  "A SQL statement and the parameters bound to it so far, not yet executed.
Build one with SQL, add parameters with PARAM or PARAMS, and finish it with
QUERY or UPDATE."
  (client nil)
  (sql "" :type string)
  (named '() :type list)
  (indexed '() :type list))

(defstruct (result-spec (:constructor %make-result-spec) (:copier nil))
  "A statement together with the row format its result will be built in.
Produced by QUERY and consumed by ROWS, SINGLE, OPTIONAL, VALUE and COLUMN."
  (statement nil)
  (format :plist))

(defvar *unbound-marker* (list :unbound)
  "Unique object standing for \"nothing was bound here\".
Needed because NIL and :NULL are both perfectly good parameter values.")

(defun sql (client sql)
  "Begin a statement against CLIENT for the given SQL text.
Placeholders may be named (:id) or PostgreSQL's own positional ones ($1); see
PARSE-NAMED-PARAMETERS for exactly how named ones are recognised."
  (%make-statement :client client :sql sql))

;;; ---------------------------------------------------------------------
;;; Parameter binding
;;; ---------------------------------------------------------------------

(defun statement-parsed (statement)
  "Return the $N form of STATEMENT's SQL and its parameter names, via the
client's parse cache."
  (let* ((client (statement-client statement))
         (sql (statement-sql statement))
         (cache (%client-parse-cache client)))
    (let ((entry (gethash sql cache)))
      (unless entry
        (when (>= (hash-table-count cache) *statement-cache-size*)
          (clrhash cache))
        (setf entry (multiple-value-bind (converted names) (parse-named-parameters sql)
                      (cons converted names))
              (gethash sql cache) entry))
      (values (car entry) (cdr entry)))))

(defun param (statement name value)
  "Return a copy of STATEMENT with VALUE bound to NAME.
NAME is a named placeholder -- a keyword, symbol or string, matched case- and
underscore-insensitively -- or a positive integer for the Nth positional
placeholder."
  (let ((copy (%copy-statement statement)))
    (if (integerp name)
        (setf (statement-indexed copy)
              (acons name value (statement-indexed copy)))
        (setf (statement-named copy)
              (list* (normalize-parameter-name name) value (statement-named copy))))
    copy))

(defun bind-named (statement parameters)
  "Return a copy of STATEMENT with the named PARAMETERS bound."
  (let ((copy (%copy-statement statement)))
    (flet ((bind (name value)
             (setf (statement-named copy)
                   (list* (normalize-parameter-name name) value
                          (statement-named copy)))))
      (etypecase parameters
        (hash-table (maphash #'bind parameters))
        (list
         (if (consp (first parameters))
             (loop :for (name . value) :in parameters :do (bind name value))
             (progn
               (when (oddp (length parameters))
                 (%parameter-error (statement-sql statement)
                                   "Property list of parameters has an odd length"))
               (loop :for (name value) :on parameters :by #'cddr
                     :do (bind name value)))))))
    copy))

(defun bind-positional (statement parameters)
  "Return a copy of STATEMENT with PARAMETERS bound to $1 upwards."
  (let ((copy (%copy-statement statement)))
    (setf (statement-indexed copy)
          (append (loop :for value :in (coerce parameters 'list)
                        :for index :from 1
                        :collect (cons index value))
                  (statement-indexed copy)))
    copy))

(defun params (statement parameters)
  "Return a copy of STATEMENT with PARAMETERS bound in one go.

How PARAMETERS is read follows from the SQL rather than from its own shape, so
there is nothing to disambiguate: a statement with named placeholders takes a
property list, an association list or a hash table, and one with positional
placeholders takes a sequence of values for $1 upwards."
  (multiple-value-bind (converted names) (statement-parsed statement)
    (declare (ignore converted))
    (if names
        (bind-named statement parameters)
        (bind-positional statement parameters))))

(defun named-arguments (statement names)
  "Return the values bound to NAMES, in order, or signal PARAMETER-ERROR."
  (let ((bindings (statement-named statement)))
    (loop :for name :in names
          :collect (let ((value (getf bindings name *unbound-marker*)))
                     (when (eq value *unbound-marker*)
                       (%parameter-error (statement-sql statement)
                                         "No value bound for named parameter"
                                         name))
                     value))))

(defun indexed-arguments (statement)
  "Return the positionally bound values of STATEMENT in $1 order.
Signals PARAMETER-ERROR when an index in the middle of the range is unbound."
  (let ((bindings (statement-indexed statement)))
    (when bindings
      (let ((highest (reduce #'max bindings :key #'car)))
        (loop :for index :from 1 :to highest
              :collect (let ((entry (assoc index bindings)))
                         (unless entry
                           (%parameter-error (statement-sql statement)
                                             "No value bound for positional parameter"
                                             index))
                         (cdr entry)))))))

(defun statement-arguments (statement)
  "Return the $N form of STATEMENT's SQL and the argument list to execute it with."
  (multiple-value-bind (converted names) (statement-parsed statement)
    (values converted
            (if names
                (named-arguments statement names)
                (indexed-arguments statement)))))

;;; ---------------------------------------------------------------------
;;; Prepared statements
;;; ---------------------------------------------------------------------

(defun prepared-statement-name (client sql)
  "Return the name under which SQL is prepared on CLIENT's connection,
preparing it if this is the first time."
  (let ((cache (%client-statement-cache client)))
    (or (gethash sql cache)
        (progn
          (when (>= (hash-table-count cache) *statement-cache-size*)
            (clear-statement-cache client))
          (let ((name (format nil "pgc~d" (incf (%client-statement-counter client)))))
            (cl-postgres:prepare-query (%client-connection client) name sql)
            (setf (gethash sql cache) name))))))

(defun stale-statement-error-p (condition)
  "True when CONDITION means the statement we had prepared is no longer usable,
so re-preparing it is worth one attempt.

That happens when the server never had it or has dropped it (26000), and when a
cached plan's result type changed under us because the schema did (0A000 with
that specific message; 0A000 covers plenty of errors that would only repeat)."
  (let ((code (cl-postgres:database-error-code condition)))
    (or (equal code "26000")
        (and (equal code "0A000")
             (search "cached plan"
                     (or (cl-postgres:database-error-message condition) ""))))))

(defun execute-prepared (client sql arguments reader)
  "Execute SQL on CLIENT with ARGUMENTS, reading the result with READER.
SQL must already be in $N form."
  (let ((connection (%client-connection client)))
    (flet ((run (name)
             (cl-postgres:exec-prepared connection name arguments reader)))
      (handler-case (run (prepared-statement-name client sql))
        (cl-postgres:database-error (condition)
          (unless (stale-statement-error-p condition)
            (error condition))
          (remhash sql (%client-statement-cache client))
          (run (prepared-statement-name client sql)))))))

(defun execute-statement (statement reader)
  "Execute STATEMENT, reading its result with READER.
Returns what READER returned, and the number of affected rows as a second value.

A statement with no parameters goes out over the simple query protocol, which
saves a round trip and, unlike a prepared statement, allows the server-side
utility commands that cannot be prepared at all."
  (let ((client (statement-client statement)))
    (multiple-value-bind (sql arguments) (statement-arguments statement)
      (if arguments
          (execute-prepared client sql arguments reader)
          (cl-postgres:exec-query (%client-connection client) sql reader)))))
