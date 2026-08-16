;;;; t/copy-test.lisp
;;;;
;;;; Bulk loading over COPY.

(in-package #:cl-postgres-client/test)

(deftest copying
  (with-users (client)
    (testing "copy-rows loads every row and returns the count"
      (ok (= 2 (pgc:copy-rows client "users"
                              '((10 "jane" 25) (11 "karl" 35))
                              :columns '("id" "name" "age"))))
      (ok (= 5 (pgc:query-value client "select count(*) from users")))
      (ok (equal '("jane" "karl")
                 (pgc:query-column client
                                   "select name from users where id >= 10 order by id"))))

    (testing "copy-rows accepts vectors as rows"
      (let ((rows (vector (vector 12 "lena" 45))))
        (ok (= 1 (pgc:copy-rows client "users" rows :columns '("id" "name" "age"))))
        (ok (equal "lena" (pgc:query-value client "select name from users where id = 12")))))

    (testing "an empty load is a no-op"
      (ok (= 0 (pgc:copy-rows client "users" '() :columns '("id" "name")))))))

(deftest copying-is-undone-by-the-surrounding-transaction
  (with-users (client)
    (testing "rows written before an error do not survive"
      (ok (signals (pgc:with-transaction (client)
                     (pgc:with-copy-writer (writer client "users" :columns '("id" "name"))
                       (pgc:copy-write-row writer '(20 "partial"))
                       (error "boom")))
                   'simple-error))
      (ok (= 0 (pgc:query-value client "select count(*) from users where id = 20"))))

    (testing "the connection is still usable"
      (ok (= 3 (pgc:query-value client "select count(*) from users"))))))

(deftest copying-quotes-identifiers
  (with-test-client (client)
    (pgc:execute client "drop table if exists \"odd name\"")
    (pgc:execute client "create table \"odd name\" (\"select\" integer)")
    (unwind-protect
         (testing "a table and column name that need quoting are quoted"
           (ok (= 2 (pgc:copy-rows client "odd name" '((1) (2)) :columns '("select"))))
           (ok (= 2 (pgc:query-value client "select count(*) from \"odd name\""))))
      (pgc:execute client "drop table if exists \"odd name\""))))
