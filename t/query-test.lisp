;;;; t/query-test.lisp
;;;;
;;;; Reading: the one-line forms, the fluent forms, and the ways parameters can
;;;; be handed over.
;;;;
;;;; The one-line and the fluent forms are checked against each other rather
;;;; than only against expected values, since the whole point of building one
;;;; out of the other is that they cannot disagree.

(in-package #:cl-postgres-client/test)

(deftest one-line-queries
  (with-users (client)
    (testing "query-list returns every row"
      (ok (equal (pgc:query-list client "select id, name from users order by id")
                 '((:id 1 :name "alice") (:id 2 :name "bob") (:id 3 :name "carol")))))

    (testing "query-list binds named parameters"
      (ok (equal (pgc:query-list client
                                 "select name from users where age > :age order by id"
                                 :params '(:age 25) :as :value)
                 '("alice" "carol"))))

    (testing "query-single returns the one row"
      (ok (equal (pgc:query-single client "select id, name from users where id = :id"
                                   :params '(:id 2))
                 '(:id 2 :name "bob"))))

    (testing "query-optional returns nil when there is no row"
      (ok (null (pgc:query-optional client "select id from users where id = :id"
                                    :params '(:id 99)))))

    (testing "query-value returns the single value"
      (ok (= 3 (pgc:query-value client "select count(*) from users"))))

    (testing "query-column returns the first column of every row"
      (ok (equal (pgc:query-column client "select name from users order by id")
                 '("alice" "bob" "carol"))))))

(deftest fluent-queries
  (with-users (client)
    (testing "sql, param and query compose into the same result as the one-line form"
      (ok (equal (pgc:-> (pgc:sql client "select id, name from users where id = :id")
                         (pgc:param :id 2)
                         (pgc:query)
                         (pgc:single))
                 (pgc:query-single client "select id, name from users where id = :id"
                                   :params '(:id 2)))))

    (testing "query :as :value followed by optional yields the bare value"
      (ok (equal (pgc:-> (pgc:sql client "select age from users where id = :id")
                         (pgc:param :id 3)
                         (pgc:query :as :value)
                         (pgc:optional))
                 40)))

    (testing "optional yields nil for a missing row"
      (ok (null (pgc:-> (pgc:sql client "select age from users where id = :id")
                        (pgc:param :id 99)
                        (pgc:query :as :value)
                        (pgc:optional)))))

    (testing "value and column force the single-column format"
      (ok (= 3 (pgc:-> (pgc:sql client "select count(*) from users") (pgc:value))))
      (ok (equal (pgc:-> (pgc:sql client "select name from users order by id")
                         (pgc:column))
                 '("alice" "bob" "carol"))))

    (testing "a statement is immutable, so one base can be finished many ways"
      (let ((base (pgc:sql client "select name from users where id = :id")))
        (ok (equal (pgc:value (pgc:param base :id 1)) "alice"))
        (ok (equal (pgc:value (pgc:param base :id 3)) "carol"))))))

(deftest parameter-binding
  (with-users (client)
    (testing "params accepts a property list"
      (ok (equal (pgc:-> (pgc:sql client "select name from users where age = :age")
                         (pgc:params '(:age 20))
                         (pgc:value))
                 "bob")))

    (testing "params accepts an association list"
      (ok (equal (pgc:-> (pgc:sql client "select name from users where age = :age")
                         (pgc:params '((:age . 20)))
                         (pgc:value))
                 "bob")))

    (testing "params accepts a hash table"
      (let ((table (make-hash-table)))
        (setf (gethash :age table) 20)
        (ok (equal (pgc:-> (pgc:sql client "select name from users where age = :age")
                           (pgc:params table)
                           (pgc:value))
                   "bob"))))

    (testing "params binds a plain list positionally for $n placeholders"
      (ok (equal (pgc:query-value client "select name from users where id = $1 and age = $2"
                                  :params '(2 20))
                 "bob")))

    (testing "param binds a positional placeholder by index"
      (ok (equal (pgc:-> (pgc:sql client "select name from users where id = $1")
                         (pgc:param 1 3)
                         (pgc:value))
                 "carol")))

    (testing "a name matches whether it is written with a hyphen or an underscore"
      (ok (= 1 (pgc:query-value client "select id from users where name = :user_name"
                                :params '(:user-name "alice")))))

    (testing "a repeated name is bound once"
      (ok (equal (pgc:query-column client
                                   "select name from users where id = :id or age = :id * 10
                                    order by id"
                                   :params '(:id 2))
                 '("bob"))))

    (testing "a parameter can be :null"
      (ok (equal (pgc:query-column client
                                   "select name from users where note is not distinct from :note
                                    order by id"
                                   :params '(:note :null))
                 '("bob"))))))

(deftest query-cardinality-errors
  (with-users (client)
    (testing "single with no row signals empty-result-error"
      (ok (signals (pgc:query-single client "select id from users where id = 99")
                   'pgc:empty-result-error)))

    (testing "single with several rows signals too-many-rows-error"
      (ok (signals (pgc:query-single client "select id from users") 'pgc:too-many-rows-error)))

    (testing "optional with several rows signals too-many-rows-error"
      (ok (signals (pgc:query-optional client "select id from users")
                   'pgc:too-many-rows-error)))

    (testing "too-many-rows-error reports how many there were"
      (handler-case (pgc:query-single client "select id from users")
        (pgc:too-many-rows-error (condition)
          (ok (= 3 (pgc:error-row-count condition))))))

    (testing "value with several columns signals too-many-columns-error"
      (ok (signals (pgc:query-value client "select id, name from users where id = 1")
                   'pgc:too-many-columns-error)))

    (testing "the connection is still usable after a cardinality error"
      (ok (= 3 (pgc:query-value client "select count(*) from users"))))))

(deftest parameter-errors
  (with-users (client)
    (testing "an unbound named parameter signals parameter-error"
      (ok (signals (pgc:query-value client "select id from users where id = :id")
                   'pgc:parameter-error)))

    (testing "parameter-error names the parameter it could not bind"
      (handler-case (pgc:query-value client "select id from users where name = :who")
        (pgc:parameter-error (condition)
          (ok (eq :who (pgc:error-parameter-name condition))))))

    (testing "a property list of odd length signals parameter-error"
      (ok (signals (pgc:query-value client "select id from users where id = :id"
                                    :params '(:id))
                   'pgc:parameter-error)))))
