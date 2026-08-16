;;;; t/update-test.lisp
;;;;
;;;; Writing: update in both styles, batches, RETURNING, and DDL.

(in-package #:cl-postgres-client/test)

(deftest updating
  (with-users (client)
    (testing "update returns the number of rows it affected"
      (ok (= 1 (pgc:update client "insert into users (id, name, age) values (:id, :name, :age)"
                           :params '(:id 4 :name "dave" :age 50))))
      (ok (= 4 (pgc:query-value client "select count(*) from users"))))

    (testing "update in the fluent style"
      (ok (= 1 (pgc:-> (pgc:sql client "update users set age = :age where id = :id")
                       (pgc:param :age 31)
                       (pgc:param :id 1)
                       (pgc:update))))
      (ok (= 31 (pgc:query-value client "select age from users where id = 1"))))

    (testing "update reports zero when nothing matched"
      (ok (= 0 (pgc:update client "update users set age = 1 where id = :id"
                           :params '(:id 99)))))

    (testing "delete"
      (ok (= 1 (pgc:update client "delete from users where id = :id" :params '(:id 4))))
      (ok (= 3 (pgc:query-value client "select count(*) from users"))))))

(deftest returning-clause
  (with-users (client)
    (testing "rows from RETURNING come back through query"
      (ok (equal (pgc:query-single client
                                   "insert into users (id, name, age) values (:id, :name, :age)
                                    returning id, name"
                                   :params '(:id 5 :name "erin" :age 60))
                 '(:id 5 :name "erin"))))

    (testing "RETURNING on an update of several rows"
      (ok (equal (pgc:query-column client
                                   "update users set age = age + 1 where id in (1, 2)
                                    returning id")
                 '(1 2))))))

(deftest batch-updating
  (with-users (client)
    (testing "batch-update runs once per parameter set"
      (ok (equal (pgc:batch-update client
                                   "insert into users (id, name, age) values (:id, :name, :age)"
                                   '((:id 10 :name "j" :age 10)
                                     (:id 11 :name "k" :age 11)
                                     (:id 12 :name "l" :age 12)))
                 '(1 1 1)))
      (ok (= 6 (pgc:query-value client "select count(*) from users"))))

    (testing "an empty batch does nothing"
      (ok (null (pgc:batch-update client "delete from users where id = :id" '()))))))

(deftest executing-statements
  (with-test-client (client)
    (testing "execute runs DDL"
      (pgc:execute client "drop table if exists widgets")
      (pgc:execute client "create table widgets (id integer)")
      (ok (= 0 (pgc:query-value client "select count(*) from widgets")))
      (pgc:execute client "drop table widgets"))

    (testing "execute runs the utility commands a prepared statement cannot"
      (pgc:execute client "set application_name = 'pgc-test'")
      (ok (equal "pgc-test" (pgc:query-value client "show application_name"))))))
