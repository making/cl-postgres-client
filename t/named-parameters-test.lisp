;;;; t/named-parameters-test.lisp
;;;;
;;;; The placeholder scanner, which is pure and therefore the one file in the
;;;; suite that runs with no database in sight.
;;;;
;;;; Most of these cases are about what must NOT become a parameter. A colon in
;;;; PostgreSQL means half a dozen things, and every one of them below was a way
;;;; to break valid SQL with a naive search and replace.

(in-package #:cl-postgres-client/test)

(defun rewrite (sql)
  "Return the rewritten SQL and its parameter names as a single list, so a test
can compare both at once."
  (multiple-value-bind (converted names) (pgc:parse-named-parameters sql)
    (list converted names)))

(deftest named-parameters
  (testing "rewrites a named placeholder into $1"
    (ok (equal (rewrite "select * from users where id = :id")
               '("select * from users where id = $1" (:id)))))

  (testing "numbers placeholders in the order they appear"
    (ok (equal (rewrite "select * from users where age > :age and name = :name")
               '("select * from users where age > $1 and name = $2" (:age :name)))))

  (testing "gives a repeated name a single placeholder"
    (ok (equal (rewrite "select * from t where a = :x or b = :x")
               '("select * from t where a = $1 or b = $1" (:x)))))

  (testing "reads snake_case placeholders as kebab-case keywords"
    (ok (equal (rewrite "select * from users where user_name = :user_name")
               '("select * from users where user_name = $1" (:user-name)))))

  (testing "leaves SQL without named placeholders exactly as it was"
    (let ((sql "select * from users where id = $1"))
      (ok (equal (rewrite sql) (list sql nil)))))

  (testing "returns no names for SQL without parameters"
    (ok (equal (rewrite "select 1") '("select 1" nil)))))

(deftest named-parameters-are-not-found-in
  (testing "a cast"
    (ok (equal (rewrite "select id::integer from t")
               '("select id::integer from t" nil))))

  (testing "a cast that is followed by a real parameter"
    (ok (equal (rewrite "select :n::integer + id::bigint from t")
               '("select $1::integer + id::bigint from t" (:n)))))

  (testing "an assignment"
    (ok (equal (rewrite "call f(a := 1)") '("call f(a := 1)" nil))))

  (testing "an array slice"
    (ok (equal (rewrite "select tags[1:3] from t") '("select tags[1:3] from t" nil))))

  (testing "a string literal"
    (ok (equal (rewrite "select ':id' from t") '("select ':id' from t" nil))))

  (testing "a string literal with a doubled quote in it"
    (ok (equal (rewrite "select 'it''s :not a param' from t where id = :id")
               '("select 'it''s :not a param' from t where id = $1" (:id)))))

  (testing "an E-string where a backslash escapes the closing quote"
    (ok (equal (rewrite "select E'\\':x' from t where id = :id")
               '("select E'\\':x' from t where id = $1" (:id)))))

  (testing "a quoted identifier"
    (ok (equal (rewrite "select \":id\" from t") '("select \":id\" from t" nil))))

  (testing "a dollar-quoted body"
    (ok (equal (rewrite "select $$ :id $$ from t") '("select $$ :id $$ from t" nil))))

  (testing "a tagged dollar-quoted body"
    (ok (equal (rewrite "select $fn$ begin :x; end $fn$ from t where id = :id")
               '("select $fn$ begin :x; end $fn$ from t where id = $1" (:id)))))

  (testing "a line comment"
    (ok (equal (rewrite (format nil "select 1 -- :nope~%from t where id = :id"))
               (list (format nil "select 1 -- :nope~%from t where id = $1") '(:id)))))

  (testing "a block comment"
    (ok (equal (rewrite "select /* :nope */ 1 from t where id = :id")
               '("select /* :nope */ 1 from t where id = $1" (:id)))))

  (testing "a nested block comment"
    (ok (equal (rewrite "select /* a /* :deep */ b */ 1 where id = :id")
               '("select /* a /* :deep */ b */ 1 where id = $1" (:id))))))

(deftest quoting-identifiers
  (testing "wraps a name in double quotes"
    (ok (string= (pgc:quote-identifier "users") "\"users\"")))

  (testing "doubles an embedded double quote"
    (ok (string= (pgc:quote-identifier "we\"ird") "\"we\"\"ird\"")))

  (testing "downcases a symbol, as unquoted SQL would have"
    (ok (string= (pgc:quote-identifier :users) "\"users\""))))
