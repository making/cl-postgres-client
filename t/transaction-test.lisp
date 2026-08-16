;;;; t/transaction-test.lisp
;;;;
;;;; Transactions, savepoints and the ways out of them.

(in-package #:cl-postgres-client/test)

(defun user-count (client)
  "How many rows the users fixture currently holds."
  (pgc:query-value client "select count(*) from users"))

(defun insert-user (client id name)
  "Add one row to the users fixture."
  (pgc:update client "insert into users (id, name, age) values (:id, :name, 1)"
              :params (list :id id :name name)))

(deftest transactions
  (with-users (client)
    (testing "a body that returns normally commits"
      (pgc:with-transaction (client)
        (insert-user client 10 "j"))
      (ok (= 4 (user-count client))))

    (testing "with-transaction returns the value of its body"
      (ok (= 42 (pgc:with-transaction (client) 42))))

    (testing "an error rolls the whole transaction back"
      (ok (signals (pgc:with-transaction (client)
                     (insert-user client 11 "k")
                     (error "boom"))
                   'simple-error))
      (ok (= 4 (user-count client))))

    (testing "a non-local exit rolls back too"
      (block done
        (pgc:with-transaction (client)
          (insert-user client 12 "l")
          (return-from done)))
      (ok (= 4 (user-count client))))

    (testing "rollback-only discards the work but lets the body finish"
      (let ((reached nil))
        (pgc:with-transaction (client)
          (insert-user client 13 "m")
          (pgc:rollback-only client)
          (setf reached t))
        (ok reached)
        (ok (= 4 (user-count client)))))

    (testing "rollback-only outside a transaction is an error"
      (ok (signals (pgc:rollback-only client) 'pgc:transaction-error)))

    (testing "the client is usable again after a rolled back transaction"
      (ok (= 4 (user-count client))))))

(deftest transaction-depth-tracking
  (with-users (client)
    (testing "depth is zero outside, one inside, two in a savepoint"
      (ok (= 0 (pgc:transaction-depth client)))
      (ng (pgc:in-transaction-p client))
      (pgc:with-transaction (client)
        (ok (= 1 (pgc:transaction-depth client)))
        (ok (pgc:in-transaction-p client))
        (pgc:with-transaction (client)
          (ok (= 2 (pgc:transaction-depth client)))))
      (ok (= 0 (pgc:transaction-depth client))))))

(deftest savepoints
  (with-users (client)
    (testing "a nested transaction that fails leaves the outer one intact"
      (pgc:with-transaction (client)
        (insert-user client 20 "t")
        (ignore-errors
         (pgc:with-transaction (client)
           (insert-user client 21 "u")
           (error "boom"))))
      (ok (= 4 (user-count client)))
      (ok (= 1 (pgc:query-value client "select count(*) from users where id = 20")))
      (ok (= 0 (pgc:query-value client "select count(*) from users where id = 21"))))

    (testing "rollback-only inside a savepoint discards only that savepoint"
      (pgc:with-transaction (client)
        (insert-user client 22 "v")
        (pgc:with-savepoint (client)
          (insert-user client 23 "w")
          (pgc:rollback-only client)))
      (ok (= 1 (pgc:query-value client "select count(*) from users where id = 22")))
      (ok (= 0 (pgc:query-value client "select count(*) from users where id = 23"))))

    (testing "a named savepoint works the same way"
      (pgc:with-transaction (client)
        (pgc:with-savepoint (client :name "my_point")
          (insert-user client 24 "x")
          (pgc:rollback-only client)))
      (ok (= 0 (pgc:query-value client "select count(*) from users where id = 24"))))

    (testing "a savepoint outside a transaction is an error"
      (ok (signals (pgc:with-savepoint (client) nil) 'pgc:transaction-error)))))

(deftest transaction-characteristics
  (with-users (client)
    (testing "the isolation level reaches the server"
      (pgc:with-transaction (client :isolation :serializable)
        (ok (equal "serializable"
                   (pgc:query-value client "show transaction_isolation"))))
      (pgc:with-transaction (client :isolation :repeatable-read)
        (ok (equal "repeatable read"
                   (pgc:query-value client "show transaction_isolation")))))

    (testing "a read-only transaction refuses to write"
      (ok (signals (pgc:with-transaction (client :read-only t)
                     (insert-user client 30 "ro"))
                   'pgc:database-error))
      (ok (= 3 (user-count client))))

    (testing "characteristics cannot be set on a nested transaction"
      (ok (signals (pgc:with-transaction (client)
                     (pgc:with-transaction (client :isolation :serializable) nil))
                   'pgc:transaction-error)))))

(deftest transaction-restart
  (with-users (client)
    (testing "the rollback restart abandons the transaction and returns nil"
      (ok (null (handler-bind ((simple-error
                                 (lambda (condition)
                                   (declare (ignore condition))
                                   (invoke-restart 'pgc:rollback))))
                  (pgc:with-transaction (client)
                    (insert-user client 40 "r")
                    (error "boom")))))
      (ok (= 0 (pgc:query-value client "select count(*) from users where id = 40"))))))
