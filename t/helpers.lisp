;;;; t/helpers.lisp
;;;;
;;;; Connection settings and fixtures shared by the suite.
;;;;
;;;; The defaults line up with docker-compose.yaml, so `make test` needs no
;;;; configuration; the environment variables exist for the case where a
;;;; PostgreSQL is already available somewhere else.
;;;;
;;;; Every test opens its own connection and closes it again. Sharing one would
;;;; be faster, but a test that leaves a broken transaction or a half-read
;;;; result behind would then take the rest of the suite down with it, and
;;;; connection setup against a local server is not what makes this suite slow.

(in-package #:cl-postgres-client/test)

(defun test-connection-options ()
  "The CONNECT arguments the suite uses, from the environment or the defaults
in docker-compose.yaml."
  (list :host (or (uiop:getenv "PGC_TEST_HOST") "localhost")
        :port (parse-integer (or (uiop:getenv "PGC_TEST_PORT") "55432"))
        :database (or (uiop:getenv "PGC_TEST_DB") "pgc_test")
        :user (or (uiop:getenv "PGC_TEST_USER") "pgc")
        :password (or (uiop:getenv "PGC_TEST_PASSWORD") "pgc")))

(defun connect-for-test ()
  "Open a client against the test database.
Notices are turned down to warnings because the fixtures open with
DROP TABLE IF EXISTS, whose notice would otherwise bury the test output."
  (let ((client (apply #'pgc:connect (test-connection-options))))
    (pgc:execute client "set client_min_messages = warning")
    client))

(defmacro with-test-client ((client) &body body)
  "Bind CLIENT to a fresh connection for the duration of BODY."
  `(let ((,client (connect-for-test)))
     (unwind-protect (progn ,@body)
       (pgc:disconnect ,client))))

(defun create-users-table (client)
  "Create the users fixture table on CLIENT, replacing any earlier one."
  (pgc:execute client "drop table if exists users")
  (pgc:execute client "create table users (
                         id   integer primary key,
                         name text not null,
                         age  integer,
                         note text)")
  (pgc:batch-update
   client
   "insert into users (id, name, age, note) values (:id, :name, :age, :note)"
   '((:id 1 :name "alice" :age 30 :note "first")
     (:id 2 :name "bob"   :age 20 :note :null)
     (:id 3 :name "carol" :age 40 :note "third")))
  client)

(defmacro with-users ((client) &body body)
  "Bind CLIENT to a fresh connection holding the users fixture table."
  `(with-test-client (,client)
     (create-users-table ,client)
     (unwind-protect (progn ,@body)
       (ignore-errors (pgc:execute ,client "drop table if exists users")))))

(defclass test-user ()
  ((id :initarg :id :reader test-user-id)
   (name :initarg :name :reader test-user-name))
  (:documentation "Target of the (:class ...) row format test."))

(defstruct test-account
  "Target of the (:struct ...) row format test."
  id
  name)
