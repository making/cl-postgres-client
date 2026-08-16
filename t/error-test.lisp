;;;; t/error-test.lisp
;;;;
;;;; What happens when PostgreSQL says no, and how the prepared-statement cache
;;;; recovers when the server has forgotten what the client remembers.

(in-package #:cl-postgres-client/test)

(deftest database-errors-pass-through
  (with-users (client)
    (testing "a constraint violation arrives as a cl-postgres database error"
      (ok (signals (pgc:update client "insert into users (id, name) values (1, 'dup')")
                   'pgc:database-error)))

    (testing "the SQLSTATE and the constraint name are readable"
      (handler-case (pgc:update client "insert into users (id, name) values (1, 'dup')")
        (pgc:database-error (condition)
          (ok (equal "23505" (pgc:database-error-code condition)))
          (ok (equal "users_pkey" (pgc:database-error-constraint-name condition)))
          (ok (stringp (pgc:database-error-message condition))))))

    (testing "a specific cl-postgres error class still matches"
      (ok (signals (pgc:update client "insert into users (id, name) values (1, 'dup')")
                   'cl-postgres-error:unique-violation)))

    (testing "a syntax error names the query"
      (handler-case (pgc:query-list client "select from where")
        (pgc:database-error (condition)
          (ok (search "select from where" (pgc:database-error-query condition))))))

    (testing "the client recovers after an error"
      (ok (= 3 (pgc:query-value client "select count(*) from users"))))))

(deftest stale-prepared-statements
  (with-users (client)
    (testing "a statement the server has deallocated is prepared again"
      (ok (= 1 (pgc:query-value client "select :n::int" :params '(:n 1))))
      (pgc:execute client "deallocate all")
      (ok (= 2 (pgc:query-value client "select :n::int" :params '(:n 2)))))

    (testing "clear-statement-cache leaves the client working"
      (ok (= 3 (pgc:query-value client "select :n::int" :params '(:n 3))))
      (pgc:clear-statement-cache client)
      (ok (= 4 (pgc:query-value client "select :n::int" :params '(:n 4)))))

    (testing "the cache is bounded and refills itself"
      (let ((pgc:*statement-cache-size* 4))
        (dotimes (index 12)
          (ok (= index (pgc:query-value client
                                        (format nil "select :n::int + ~d - ~d" index index)
                                        :params (list :n index)))))))))
