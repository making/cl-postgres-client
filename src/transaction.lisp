;;;; src/transaction.lisp
;;;;
;;;; Transactions and savepoints, which cl-postgres leaves entirely to its
;;;; callers.
;;;;
;;;; A nested WITH-TRANSACTION becomes a savepoint rather than a second BEGIN,
;;;; because PostgreSQL has no nested transactions and a second BEGIN is merely
;;;; a warning followed by silence -- the inner scope would then have no way to
;;;; roll back its own work.
;;;;
;;;; Requesting an isolation level on a nested scope is an error rather than a
;;;; no-op: the level is fixed for the whole transaction, so honouring the
;;;; request is impossible and ignoring it would hand the caller a guarantee it
;;;; does not have.

(in-package #:postgres-client)

(defun transaction-depth (client)
  "How deeply CLIENT is nested in transactions: 0 outside one, 1 inside a
transaction, 2 or more inside savepoints."
  (%client-transaction-depth client))

(defun in-transaction-p (client)
  "True when CLIENT is inside a transaction."
  (plusp (%client-transaction-depth client)))

(defun rollback-only (client)
  "Mark the innermost transaction scope of CLIENT so that it rolls back on exit
instead of committing. The body keeps running; only its effects are discarded.
Inside a savepoint scope only that savepoint is rolled back."
  (unless (in-transaction-p client)
    (%transaction-error "ROLLBACK-ONLY was called outside a transaction"))
  (setf (%client-rollback-only client) t)
  (values))

(defun isolation-level-name (isolation)
  "Return the SQL spelling of the ISOLATION keyword."
  (ecase isolation
    (:read-uncommitted "READ UNCOMMITTED")
    (:read-committed "READ COMMITTED")
    (:repeatable-read "REPEATABLE READ")
    (:serializable "SERIALIZABLE")))

(defun begin-command (isolation read-only deferrable)
  "Build the BEGIN statement for the given transaction characteristics."
  (with-output-to-string (out)
    (write-string "BEGIN" out)
    (when isolation
      (format out " ISOLATION LEVEL ~a" (isolation-level-name isolation)))
    (when read-only (write-string " READ ONLY" out))
    (when deferrable (write-string " DEFERRABLE" out))))

(defun call-with-savepoint (client thunk &optional name)
  "Run THUNK inside a savepoint on CLIENT. See WITH-SAVEPOINT."
  (unless (in-transaction-p client)
    (%transaction-error "A savepoint needs a transaction to sit inside"))
  (let* ((savepoint (quote-identifier
                     (or name
                         (format nil "pgc_sp~d" (incf (%client-savepoint-counter client))))))
         (outer-rollback-only (%client-rollback-only client))
         (settled nil))
    (flet ((undo ()
             (execute client (concatenate 'string "ROLLBACK TO SAVEPOINT " savepoint))
             (execute client (concatenate 'string "RELEASE SAVEPOINT " savepoint))))
      (execute client (concatenate 'string "SAVEPOINT " savepoint))
      (incf (%client-transaction-depth client))
      (setf (%client-rollback-only client) nil)
      (unwind-protect
           (multiple-value-prog1
               (restart-case (funcall thunk)
                 (rollback ()
                   :report "Roll back to the savepoint and return NIL."
                   (setf (%client-rollback-only client) t)
                   nil))
             (if (%client-rollback-only client)
                 (undo)
                 (execute client (concatenate 'string "RELEASE SAVEPOINT " savepoint)))
             (setf settled t))
        (unless settled (ignore-errors (undo)))
        (decf (%client-transaction-depth client))
        (setf (%client-rollback-only client) outer-rollback-only)))))

(defun call-with-transaction (client thunk &key isolation read-only deferrable)
  "Run THUNK inside a transaction on CLIENT. See WITH-TRANSACTION."
  (when (in-transaction-p client)
    (when (or isolation read-only deferrable)
      (%transaction-error
       "Isolation level, read-only and deferrable apply to a whole transaction
and cannot be set on a nested one"))
    (return-from call-with-transaction (call-with-savepoint client thunk)))
  (let ((outer-rollback-only (%client-rollback-only client))
        (settled nil))
    (execute client (begin-command isolation read-only deferrable))
    (setf (%client-transaction-depth client) 1
          (%client-rollback-only client) nil)
    (unwind-protect
         (multiple-value-prog1
             (restart-case (funcall thunk)
               (rollback ()
                 :report "Roll back the transaction and return NIL."
                 (setf (%client-rollback-only client) t)
                 nil))
           (execute client (if (%client-rollback-only client) "ROLLBACK" "COMMIT"))
           (setf settled t))
      (unless settled (ignore-errors (execute client "ROLLBACK")))
      (setf (%client-transaction-depth client) 0
            (%client-rollback-only client) outer-rollback-only))))

(defmacro with-transaction ((client &key isolation read-only deferrable) &body body)
  "Run BODY inside a transaction on CLIENT, committing on normal exit and
rolling back on any non-local exit.

ISOLATION is :READ-UNCOMMITTED, :READ-COMMITTED, :REPEATABLE-READ or
:SERIALIZABLE; READ-ONLY and DEFERRABLE are booleans. None of the three may be
given on a nested WITH-TRANSACTION, which becomes a savepoint and cannot change
the enclosing transaction's characteristics.

Call ROLLBACK-ONLY to finish the body normally but discard its work. A ROLLBACK
restart is established around BODY for use from the debugger.

    (pgc:with-transaction (client :isolation :serializable)
      (pgc:update client \"update accounts set balance = balance - :n where id = :from\"
                  :params '(:n 100 :from 1))
      (pgc:update client \"update accounts set balance = balance + :n where id = :to\"
                  :params '(:n 100 :to 2)))"
  `(call-with-transaction ,client (lambda () ,@body)
                          :isolation ,isolation
                          :read-only ,read-only
                          :deferrable ,deferrable))

(defmacro with-savepoint ((client &key name) &body body)
  "Run BODY inside a savepoint on CLIENT, releasing it on normal exit and
rolling back to it on any non-local exit. NAME defaults to a generated one.
Signals TRANSACTION-ERROR when there is no transaction to sit inside."
  `(call-with-savepoint ,client (lambda () ,@body) ,name))
