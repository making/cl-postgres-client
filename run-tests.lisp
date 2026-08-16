;;;; run-tests.lisp
;;;;
;;;; Entry point for `sbcl --script run-tests.lisp`.
;;;;
;;;; Dependency resolution is deliberately layered: a project-local Quicklisp
;;;; installed by `make deps` wins, then the developer's own ~/quicklisp, and
;;;; finally a plain ASDF configuration.  That way the suite runs on a machine
;;;; with no Lisp package manager installed at all without ever writing outside
;;;; this checkout.

(require :asdf)

(defun script-directory ()
  (make-pathname :name nil
                 :type nil
                 :defaults (or *load-truename*
                               *compile-file-truename*
                               (error "Unable to determine the script location"))))

(defun load-quicklisp (root)
  "Load the first Quicklisp setup file found, or NIL when there is none."
  (let ((setup (find-if #'probe-file
                        (list (merge-pathnames ".quicklisp/setup.lisp" root)
                              (merge-pathnames "quicklisp/setup.lisp"
                                               (user-homedir-pathname))))))
    (when setup
      (load setup)
      t)))

(let ((root (script-directory)))
  (asdf:initialize-source-registry
   `(:source-registry (:tree ,root) :inherit-configuration))
  (if (load-quicklisp root)
      (funcall (find-symbol "QUICKLOAD" "QUICKLISP-CLIENT") "cl-postgres-client/test")
      (asdf:load-system "cl-postgres-client/test"))
  ;; Calling the suite directly rather than through ASDF:TEST-SYSTEM, because
  ;; rove reloads the system it is asked to run and doing that from inside an
  ;; ASDF operation is a needless nesting.
  (uiop:quit
   (if (funcall (find-symbol "RUN-TESTS" "CL-POSTGRES-CLIENT/TEST")) 0 1)))
