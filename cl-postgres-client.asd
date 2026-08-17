;;;; cl-postgres-client.asd
(asdf:defsystem "cl-postgres-client"
  :description "A high-level PostgreSQL client on top of cl-postgres, in the style of Spring's JdbcClient"
  :long-description "Adds named parameters, row mapping (plist/alist/hash-table/CLOS/struct),
transactions with savepoints, streaming, COPY and LISTEN/NOTIFY on top of cl-postgres,
behind both a fluent statement builder and one-line convenience functions.
cl-postgres is the only runtime dependency."
  :version "0.1.0"
  :author "Toshiaki Maki <makingx@gmail.com>"
  :maintainer "Toshiaki Maki <makingx@gmail.com>"
  :license "MIT"
  :homepage "https://github.com/making/cl-postgres-client"
  :bug-tracker "https://github.com/making/cl-postgres-client/issues"
  :source-control (:git "https://github.com/making/cl-postgres-client.git")
  :depends-on ("cl-postgres")
  :pathname "src"
  :serial t
  :components ((:file "package")
               (:file "conditions")
               (:file "named-parameters")
               (:file "row-mapper")
               (:file "client")
               (:file "statement")
               (:file "execute")
               (:file "transaction")
               (:file "copy")
               (:file "notification"))
  :in-order-to ((test-op (test-op "cl-postgres-client/test"))))

(asdf:defsystem "cl-postgres-client/test"
  :description "Test system for cl-postgres-client"
  :version "0.1.0"
  :author "Toshiaki Maki <makingx@gmail.com>"
  :maintainer "Toshiaki Maki <makingx@gmail.com>"
  :license "MIT"
  :homepage "https://github.com/making/cl-postgres-client"
  :bug-tracker "https://github.com/making/cl-postgres-client/issues"
  :source-control (:git "https://github.com/making/cl-postgres-client.git")
  :depends-on ("cl-postgres-client" "rove")
  :pathname "t"
  :serial t
  :components ((:file "package")
               (:file "helpers")
               (:file "package-test")
               (:file "named-parameters-test")
               (:file "client-test")
               (:file "query-test")
               (:file "row-mapper-test")
               (:file "update-test")
               (:file "transaction-test")
               (:file "streaming-test")
               (:file "copy-test")
               (:file "notification-test")
               (:file "error-test"))
  ;; ROVE:RUN is named rather than this system's own RUN-TESTS because a .asd is
  ;; read before either package exists, so the call has to be made by name at
  ;; run time -- and a name that the test runner itself calls is the one certain
  ;; to be present in whatever image is performing the operation.
  :perform (test-op (operation component)
             (declare (ignore operation component))
             (unless (funcall (find-symbol "RUN" "ROVE") :cl-postgres-client/test)
               (error "cl-postgres-client test suite failed"))))
