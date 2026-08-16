;;;; t/client-test.lisp
;;;;
;;;; Connection lifecycle.

(in-package #:cl-postgres-client/test)

(deftest connecting
  (testing "connect returns an open client"
    (let ((client (connect-for-test)))
      (unwind-protect
           (progn (ok (pgc:client-p client))
                  (ok (pgc:connected-p client))
                  (ok (equal '(1) (pgc:query-list client "select 1" :as :value))))
        (pgc:disconnect client))))

  (testing "disconnect closes the client, and does so idempotently"
    (let ((client (connect-for-test)))
      (pgc:disconnect client)
      (ng (pgc:connected-p client))
      (pgc:disconnect client)
      (ng (pgc:connected-p client))))

  (testing "with-client disconnects even when the body unwinds"
    (let ((options (test-connection-options))
          (escaped nil))
      (ok (signals (pgc:with-client (client :host (getf options :host)
                                            :port (getf options :port)
                                            :database (getf options :database)
                                            :user (getf options :user)
                                            :password (getf options :password))
                     (setf escaped client)
                     (error "boom"))
                   'simple-error))
      (ng (pgc:connected-p escaped))))

  (testing "connect insists on a database and a user"
    (ok (signals (pgc:connect :host "localhost") 'error))))

(deftest wrapping-an-existing-connection
  (testing "wrap-connection puts the API on a cl-postgres connection"
    (let* ((options (test-connection-options))
           (connection (cl-postgres:open-database (getf options :database)
                                                  (getf options :user)
                                                  (getf options :password)
                                                  (getf options :host)
                                                  (getf options :port))))
      (unwind-protect
           (let ((client (pgc:wrap-connection connection)))
             (ok (eq connection (pgc:client-connection client)))
             (ok (= 7 (pgc:query-value client "select 3 + 4"))))
        (cl-postgres:close-database connection)))))

(deftest reconnecting
  (testing "reconnect reopens the connection and forgets its prepared statements"
    (with-test-client (client)
      (ok (= 1 (pgc:query-value client "select :n::int" :params '(:n 1))))
      (pgc:disconnect client)
      (pgc:reconnect client)
      (ok (pgc:connected-p client))
      (ok (= 2 (pgc:query-value client "select :n::int" :params '(:n 2)))))))
