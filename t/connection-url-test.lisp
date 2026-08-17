;;;; t/connection-url-test.lisp
;;;;
;;;; The connection-URL parser, which is pure and therefore runs with no
;;;; database in sight.  The test that a parsed URL really is what CONNECT
;;;; wants lives with the other connection tests, where a server is available.
;;;;
;;;; Most of these cases are about a delimiter that is not one: the @ of a
;;;; percent-encoded password, the colons of an IPv6 literal, a : that belongs
;;;; to the port and one that belongs to the password.

(in-package #:cl-postgres-client/test)

(defun url-option (url key)
  "The single CONNECT argument KEY that URL asks for."
  (getf (pgc:parse-connection-url url) key))

(defun url-error (url)
  "The condition PARSE-CONNECTION-URL signals for URL, or NIL when it accepts it."
  (caught-condition (pgc:parse-connection-url url)))

(deftest connection-urls
  (testing "takes a complete URL apart"
    (ok (equal (pgc:parse-connection-url
                "postgresql://app:secret@db.internal:5432/app")
               '(:database "app" :user "app" :host "db.internal" :port 5432
                 :password "secret"))))

  (testing "reads the postgres:// scheme as well"
    (ok (equal (pgc:parse-connection-url "postgres://app@db.internal/app")
               '(:database "app" :user "app" :host "db.internal"))))

  (testing "leaves out the port the URL does not give"
    (ok (null (url-option "postgresql://app@db.internal/app" :port))))

  (testing "leaves out the database the URL does not give, for CONNECT to insist on"
    (ok (equal (pgc:parse-connection-url "postgresql://localhost")
               '(:host "localhost"))))

  (testing "reads a URL with nothing but a database"
    (ok (equal (pgc:parse-connection-url "postgresql:///app")
               '(:database "app"))))

  (testing "reads a URL with nothing at all"
    (ok (null (pgc:parse-connection-url "postgresql://")))))

(deftest connection-url-percent-encoding
  (testing "decodes an @ in the password rather than splitting on it"
    (ok (equal (pgc:parse-connection-url "postgresql://app:p%40ssword@db/app")
               '(:database "app" :user "app" :host "db" :password "p@ssword"))))

  (testing "decodes a colon in the password rather than splitting on it"
    (ok (string= (url-option "postgresql://app:a%3Ab@db/app" :password) "a:b")))

  (testing "decodes the user and the database too"
    (ok (equal (pgc:parse-connection-url "postgresql://a%40b@db/my%20app")
               '(:database "my app" :user "a@b" :host "db"))))

  (testing "reads the decoded bytes as UTF-8"
    (ok (string= (url-option "postgresql://app:p%C3%A4ss@db/app" :password)
                 (concatenate 'string "p" (string (code-char 228)) "ss"))))

  (testing "rejects a percent that is not an escape"
    (ok (signals (pgc:parse-connection-url "postgresql://app:1%2@db/app")
                 'pgc:connection-url-error)))

  (testing "rejects a UTF-8 character that stops short"
    (ok (signals (pgc:parse-connection-url "postgresql://app:p%C3@db/app")
                 'pgc:connection-url-error))))

(deftest connection-url-hosts
  (testing "reads an IPv6 literal without taking its colons for the port"
    (ok (equal (pgc:parse-connection-url "postgresql://[::1]:5432/app")
               '(:database "app" :host "::1" :port 5432))))

  (testing "reads an IPv6 literal with no port after it"
    (ok (equal (pgc:parse-connection-url "postgresql://[fe80::1]/app")
               '(:database "app" :host "fe80::1"))))

  (testing "rejects an IPv6 literal missing its closing bracket"
    (ok (signals (pgc:parse-connection-url "postgresql://[::1/app")
                 'pgc:connection-url-error)))

  (testing "rejects a port that is not a number"
    (ok (signals (pgc:parse-connection-url "postgresql://db:pg/app")
                 'pgc:connection-url-error)))

  (testing "reads a host parameter that is a path as the Unix domain socket"
    (ok (equal (pgc:parse-connection-url "postgresql:///app?host=/var/run/postgresql")
               '(:database "app" :host :unix)))))

(deftest connection-url-parameters
  (testing "maps each of libpq's sslmode values onto use-ssl"
    (ok (equal (mapcar (lambda (mode)
                         (url-option (concatenate 'string "postgresql:///app?sslmode=" mode)
                                     :use-ssl))
                       '("disable" "allow" "prefer" "require" "verify-ca" "verify-full"))
               '(:no :try :try :require :yes :full))))

  (testing "passes application_name straight through"
    (ok (string= (url-option "postgresql:///app?application_name=importer"
                             :application-name)
                 "importer")))

  (testing "reads several parameters at once"
    (ok (equal (pgc:parse-connection-url
                "postgresql://db/app?sslmode=require&application_name=importer")
               '(:database "app" :host "db"
                 :use-ssl :require :application-name "importer"))))

  (testing "lets a parameter win over the same component in the URL"
    (ok (string= (url-option "postgresql://db/app?dbname=other" :database) "other")))

  (testing "rejects a parameter it does not understand rather than dropping it"
    (ok (signals (pgc:parse-connection-url "postgresql:///app?target_session_attrs=any")
                 'pgc:connection-url-error)))

  (testing "rejects an sslmode it does not understand"
    (ok (signals (pgc:parse-connection-url "postgresql:///app?sslmode=maybe")
                 'pgc:connection-url-error))))

(deftest connection-urls-that-are-not
  (testing "rejects a string that is no URL at all"
    (ok (signals (pgc:parse-connection-url "db.internal:5432/app")
                 'pgc:connection-url-error)))

  (testing "rejects another database's scheme"
    (ok (signals (pgc:parse-connection-url "mysql://db.internal/app")
                 'pgc:connection-url-error)))

  (testing "carries the URL it could not read"
    (let ((url "mysql://db.internal/app"))
      (ok (string= (pgc:error-url (url-error url)) url)))))
