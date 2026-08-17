;;;; t/package-test.lisp
;;;;
;;;; The suite's own package.
;;;;
;;;; RUN-TESTS is this suite's entry point, and it is also one of ROVE's
;;;; exported symbols.  Without a shadow, USE-PACKAGE hands the inherited symbol
;;;; over and the DEFUN in package.lisp replaces rove's generic function with a
;;;; plain one -- silently on SBCL, and as a hard error on CCL, which refuses to
;;;; turn a generic function back into an ordinary one.  Nothing else in the
;;;; suite would notice, so this is where the shadow is held in place.
;;;;
;;;; No database is involved.

(in-package #:cl-postgres-client/test)

(deftest suite-package
  (testing "RUN-TESTS is this package's own symbol rather than rove's"
    (ok (not (eq 'run-tests (find-symbol "RUN-TESTS" "ROVE"))))))
