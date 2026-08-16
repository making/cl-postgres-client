;;;; src/copy.lisp
;;;;
;;;; Bulk loading over PostgreSQL's COPY protocol, which is an order of
;;;; magnitude faster than a stream of INSERTs and is what BATCH-UPDATE stops
;;;; being the right tool for somewhere in the thousands of rows.
;;;;
;;;; COPY_IN cannot be aborted through cl-postgres: CLOSE-DB-WRITER always sends
;;;; CopyDone, and its :ABORT option closes the whole connection rather than the
;;;; copy.  So an error part way through a copy would otherwise commit the rows
;;;; sent so far.  COPY-ROWS therefore runs inside a transaction, where an
;;;; unwind takes the partial load with it.

(in-package #:postgres-client)

(defun call-with-copy-writer (client table columns function)
  "Open a COPY writer on CLIENT for TABLE and COLUMNS, call FUNCTION with it,
and close it. See WITH-COPY-WRITER."
  (let ((writer (cl-postgres:open-db-writer (%client-connection client)
                                            (quote-identifier table)
                                            (mapcar #'quote-identifier columns)))
        (settled nil))
    (unwind-protect
         (multiple-value-prog1 (funcall function writer)
           (cl-postgres:close-db-writer writer)
           (setf settled t))
      ;; Close without :ABORT even when unwinding: :ABORT would close the
      ;; connection, and the caller's own transaction is what undoes the rows.
      (unless settled (ignore-errors (cl-postgres:close-db-writer writer))))))

(defmacro with-copy-writer ((writer client table &key columns) &body body)
  "Bind WRITER to a COPY writer for TABLE on CLIENT, run BODY, and close it.
COLUMNS is a list of column names, and defaults to every column of the table.
Write rows with COPY-WRITE-ROW.

Rows already sent are committed when the surrounding statement completes, so
wrap this in WITH-TRANSACTION if a partial load would be worse than none --
COPY-ROWS does exactly that."
  `(call-with-copy-writer ,client ,table ,columns (lambda (,writer) ,@body)))

(defun copy-write-row (writer row)
  "Write ROW, a sequence of column values, through WRITER."
  (cl-postgres:db-write-row writer (coerce row 'list))
  (values))

(defun copy-rows (client table rows &key columns)
  "Load ROWS into TABLE on CLIENT over the COPY protocol and return how many
were written. ROWS is any sequence of sequences of column values, and COLUMNS
names the columns they line up with, defaulting to all of them.

The load runs in a transaction -- a savepoint when one is already open -- so an
error part way through leaves the table as it was.

    (pgc:copy-rows client \"users\" '((1 \"alice\") (2 \"bob\"))
                   :columns '(\"id\" \"name\")) ;=> 2"
  (with-transaction (client)
    (with-copy-writer (writer client table :columns columns)
      (let ((count 0))
        (map nil (lambda (row) (copy-write-row writer row) (incf count)) rows)
        count))))
