;;;; t/notification-test.lisp
;;;;
;;;; LISTEN / NOTIFY.
;;;;
;;;; WAIT-FOR-NOTIFICATION blocks with no timeout of its own, so a bug here
;;;; would hang the suite rather than fail it. The waits are wrapped in a
;;;; deadline for that reason alone. Only SBCL can hold that deadline --
;;;; cl-postgres exposes no socket timeout, so there is nothing portable to
;;;; build one from -- and elsewhere CI's job timeout is the only net.

(in-package #:cl-postgres-client/test)

(defmacro with-deadline ((seconds) &body body)
  "Run BODY, failing rather than hanging if it takes longer than SECONDS."
  #+sbcl `(handler-case (sb-ext:with-timeout ,seconds ,@body)
            (sb-ext:timeout () (fail "timed out waiting for a notification")))
  #-sbcl `(progn ,seconds ,@body))

(deftest notifications
  (with-test-client (listener)
    (with-test-client (sender)
      (testing "a notification sent on a listened channel arrives"
        (pgc:listen-channel listener "pgc_test_channel")
        (pgc:notify sender "pgc_test_channel" "hello")
        (with-deadline (10)
          (multiple-value-bind (channel payload pid)
              (pgc:wait-for-notification listener)
            (ok (equal "pgc_test_channel" channel))
            (ok (equal "hello" payload))
            (ok (integerp pid)))))

      (testing "the payload may be empty"
        (pgc:notify sender "pgc_test_channel")
        (with-deadline (10)
          (multiple-value-bind (channel payload)
              (pgc:wait-for-notification listener)
            (ok (equal "pgc_test_channel" channel))
            (ok (equal "" payload)))))

      (testing "a notification sent in a transaction arrives on commit"
        (pgc:with-transaction (sender)
          (pgc:notify sender "pgc_test_channel" "committed"))
        (with-deadline (10)
          (multiple-value-bind (channel payload)
              (pgc:wait-for-notification listener)
            (ok (equal "pgc_test_channel" channel))
            (ok (equal "committed" payload)))))

      (testing "unlisten stops delivery"
        (pgc:unlisten-channel listener "pgc_test_channel")
        (pgc:notify sender "pgc_test_channel" "ignored")
        (ok (= 1 (pgc:query-value listener "select 1")))))))
