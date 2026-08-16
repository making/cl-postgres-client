;;;; t/streaming-test.lisp
;;;;
;;;; DO-ROWS, MAP-ROWS and FOLD-ROWS.
;;;;
;;;; The case worth the most here is leaving DO-ROWS early: the rest of the
;;;; result has to be drained before the connection is handed back, or the next
;;;; query reads the leftovers of this one.

(in-package #:cl-postgres-client/test)

(deftest streaming
  (with-users (client)
    (testing "do-rows visits every row in order"
      (let ((names '()))
        (pgc:do-rows (row client "select name from users order by id" :as :value)
          (push row names))
        (ok (equal (nreverse names) '("alice" "bob" "carol")))))

    (testing "do-rows passes parameters"
      (let ((count 0))
        (pgc:do-rows (row client "select id from users where age > :age" :params '(:age 25))
          (declare (ignore row))
          (incf count))
        (ok (= 2 count))))

    (testing "do-rows uses the default row format when given no :as"
      (let ((first-row nil))
        (pgc:do-rows (row client "select id, name from users order by id")
          (unless first-row (setf first-row row)))
        (ok (equal first-row '(:id 1 :name "alice")))))

    (testing "return leaves the loop early and yields its value"
      (ok (equal "bob"
                 (pgc:do-rows (row client "select name from users order by id" :as :value)
                   (when (string= row "bob") (return row))))))

    (testing "the connection still works after an early return"
      (ok (= 3 (pgc:query-value client "select count(*) from users"))))

    (testing "the connection still works after the body signals an error"
      (ok (signals (pgc:do-rows (row client "select id from users order by id")
                     (declare (ignore row))
                     (error "boom"))
                   'simple-error))
      (ok (= 3 (pgc:query-value client "select count(*) from users"))))

    (testing "map-rows returns the number of rows it read"
      (let ((seen 0))
        (ok (= 3 (pgc:map-rows (lambda (row) (declare (ignore row)) (incf seen))
                               client "select id from users")))
        (ok (= 3 seen))))

    (testing "fold-rows reduces the result without collecting it"
      (ok (= 90 (pgc:fold-rows #'+ 0 client "select age from users" :as :value))))))
