;;;; src/conditions.lisp
;;;;
;;;; Conditions signalled by this library itself.  They cover exactly the cases
;;;; PostgreSQL cannot report, because the mismatch is between what the caller
;;;; asked for and what came back -- a query that legitimately returned three
;;;; rows is not a database error, it is only an error for QUERY-SINGLE.
;;;;
;;;; Anything the server rejects keeps arriving as CL-POSTGRES:DATABASE-ERROR
;;;; and is never re-wrapped.

(in-package #:postgres-client)

;;; The readers are declared ahead of the conditions so that each carries a
;;; docstring; DEFINE-CONDITION has nowhere to put one.

(defgeneric error-description (condition)
  (:documentation "A sentence describing what went wrong, or NIL."))

(defgeneric error-sql (condition)
  (:documentation "The statement the condition is about, as the caller wrote it,
with named parameters still in place."))

(defgeneric error-row-count (condition)
  (:documentation "How many rows arrived where at most one was expected."))

(defgeneric error-column-count (condition)
  (:documentation "How many columns the result had where exactly one was expected."))

(defgeneric error-parameter-name (condition)
  (:documentation "The name or index of the parameter that could not be bound,
or NIL when the problem was not with one parameter in particular."))

(define-condition postgres-client-error (error)
  ((description :initarg :description :initform nil :reader error-description))
  (:documentation "Base class for every error signalled by cl-postgres-client.
Errors reported by PostgreSQL itself are CL-POSTGRES:DATABASE-ERROR and do not
inherit from this class."))

(define-condition sql-error (postgres-client-error)
  ((sql :initarg :sql :initform nil :reader error-sql))
  (:documentation "A client-side error that can be attributed to one statement.
ERROR-SQL returns that statement as the caller wrote it, with named parameters
still in place."))

(define-condition empty-result-error (sql-error)
  ()
  (:report (lambda (condition stream)
             (format stream "Expected exactly one row, got none: ~a"
                     (error-sql condition))))
  (:documentation "Signalled when a form that requires a row, such as SINGLE or
QUERY-SINGLE, gets an empty result. Use OPTIONAL or QUERY-OPTIONAL when no row
is an acceptable answer."))

(define-condition too-many-rows-error (sql-error)
  ((row-count :initarg :row-count :initform nil :reader error-row-count))
  (:report (lambda (condition stream)
             (format stream "Expected at most one row, got ~a: ~a"
                     (or (error-row-count condition) "more")
                     (error-sql condition))))
  (:documentation "Signalled when a form that requires at most one row, such as
SINGLE or OPTIONAL, gets several. ERROR-ROW-COUNT returns how many arrived."))

(define-condition too-many-columns-error (sql-error)
  ((column-count :initarg :column-count :initform nil :reader error-column-count))
  (:report (lambda (condition stream)
             (format stream "Expected exactly one column, got ~a: ~a"
                     (or (error-column-count condition) "more")
                     (error-sql condition))))
  (:documentation "Signalled when a single-column result was required, as by
VALUE, QUERY-VALUE or the :VALUE row format, but the query selects several
columns. ERROR-COLUMN-COUNT returns how many."))

(define-condition parameter-error (sql-error)
  ((parameter-name :initarg :parameter-name :initform nil :reader error-parameter-name))
  (:report (lambda (condition stream)
             (format stream "~a~@[ (parameter ~s)~]~@[: ~a~]"
                     (or (error-description condition) "Invalid parameter")
                     (error-parameter-name condition)
                     (error-sql condition))))
  (:documentation "Signalled when the parameters supplied do not fit the
statement: a named placeholder with nothing bound to it, a binding that names no
placeholder, or a parameter list of the wrong shape.  ERROR-PARAMETER-NAME
returns the offending name when there is a single one."))

(define-condition transaction-error (postgres-client-error)
  ()
  (:report (lambda (condition stream)
             (format stream "~a" (or (error-description condition)
                                     "Transaction error"))))
  (:documentation "Signalled when a transaction operation is requested outside
the scope that could carry it out, such as ROLLBACK-ONLY with no transaction in
progress."))

(defun %parameter-error (sql description &optional parameter-name)
  "Signal a PARAMETER-ERROR about SQL with DESCRIPTION, optionally naming PARAMETER-NAME."
  (error 'parameter-error
         :sql sql
         :description description
         :parameter-name parameter-name))

(defun %transaction-error (description)
  "Signal a TRANSACTION-ERROR carrying DESCRIPTION."
  (error 'transaction-error :description description))
