;;;; t/package.lisp
;;;;
;;;; One package for the whole suite.  Tests refer to the library through its
;;;; PGC nickname rather than by using the package, so every test doubles as a
;;;; sample of what a caller writes.

(defpackage #:cl-postgres-client/test
  (:use #:cl #:rove)
  (:export #:run-tests))

(in-package #:cl-postgres-client/test)

(defun run-tests ()
  "Run every test in this suite. Returns true only when all of them passed."
  (and (rove:run :cl-postgres-client/test) t))
