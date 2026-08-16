;;;; t/row-mapper-test.lisp
;;;;
;;;; The :AS row formats.

(in-package #:cl-postgres-client/test)

(deftest row-formats
  (with-users (client)
    (let ((sql "select id, name from users where id = 1"))
      (testing "plist is the default"
        (ok (equal (pgc:query-single client sql) '(:id 1 :name "alice"))))

      (testing "alist"
        (ok (equal (pgc:query-single client sql :as :alist)
                   '((:id . 1) (:name . "alice")))))

      (testing "hash-table"
        (let ((row (pgc:query-single client sql :as :hash-table)))
          (ok (= 1 (gethash :id row)))
          (ok (equal "alice" (gethash :name row)))))

      (testing "list"
        (ok (equal (pgc:query-single client sql :as :list) '(1 "alice"))))

      (testing "vector"
        (ok (equalp (pgc:query-single client sql :as :vector) #(1 "alice"))))

      (testing "value"
        (ok (= 1 (pgc:query-single client "select id from users where id = 1" :as :value))))

      (testing "a class, built through make-instance"
        (let ((row (pgc:query-single client sql :as '(:class test-user))))
          (ok (typep row 'test-user))
          (ok (= 1 (test-user-id row)))
          (ok (equal "alice" (test-user-name row)))))

      (testing "a structure, built through its default constructor"
        (let ((row (pgc:query-single client sql :as '(:struct test-account))))
          (ok (test-account-p row))
          (ok (= 1 (test-account-id row)))
          (ok (equal "alice" (test-account-name row)))))

      (testing "a function of the keys and the values"
        (ok (equal (pgc:query-single client sql
                                     :as (lambda (keys values)
                                           (declare (ignore keys))
                                           (format nil "~a/~a" (aref values 0) (aref values 1))))
                   "1/alice"))))))

(deftest column-names
  (with-test-client (client)
    (testing "snake_case columns arrive as kebab-case keywords"
      (ok (equal (pgc:query-single client "select 1 as user_id, 'x' as user_name")
                 '(:user-id 1 :user-name "x"))))

    (testing "the transformer can be replaced"
      (let ((pgc:*column-name-transformer* #'string-upcase))
        (ok (equal (pgc:query-single client "select 1 as user_id")
                   '("USER_ID" 1)))))))

(deftest null-values
  (with-users (client)
    (testing "a SQL NULL reads as :null by default"
      (ok (eq :null (pgc:query-value client "select note from users where id = 2"))))

    (testing "*null-value* chooses what NULL reads as"
      (let ((pgc:*null-value* nil))
        (ok (null (pgc:query-value client "select note from users where id = 2")))))

    (testing "a false boolean stays distinct from NULL"
      (ok (eq nil (pgc:query-value client "select false")))
      (ok (eq :null (pgc:query-value client "select null::boolean"))))))

(deftest default-row-format
  (with-users (client)
    (testing "*default-row-format* is what a query with no :as uses"
      (let ((pgc:*default-row-format* :list))
        (ok (equal (pgc:query-single client "select id, name from users where id = 1")
                   '(1 "alice")))))))
