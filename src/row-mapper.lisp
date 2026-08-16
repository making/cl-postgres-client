;;;; src/row-mapper.lisp
;;;;
;;;; Turning a PostgreSQL result into Lisp values.
;;;;
;;;; cl-postgres offers list and alist readers only.  This file adds the shapes
;;;; a caller actually wants -- plists, hash tables, CLOS instances, structures,
;;;; bare scalars -- behind one :AS argument, and does the column-name
;;;; conversion once per result rather than once per field of every row.
;;;;
;;;; Every reader here drains the remaining rows when the body unwinds.  A row
;;;; reader that stops early leaves unread rows in the socket, which would
;;;; desynchronise the connection for the next query; DO-ROWS with a RETURN in
;;;; it makes that an everyday occurrence rather than an exotic one.

(in-package #:postgres-client)

(defvar *default-row-format* :plist
  "The :AS value used by query forms that are not given one.
See ROW-MAPPER for the formats this library understands.")

(defvar *column-name-transformer* 'default-column-name-transformer
  "Function mapping a PostgreSQL column name to the key rows are built with.
The default reads snake_case as kebab-case and returns a keyword, so a
user_name column arrives as :USER-NAME.")

(defvar *null-value* :null
  "The Lisp value a SQL NULL is read as.
Defaults to :NULL, the value cl-postgres itself produces, which keeps NULL
distinguishable from a false boolean and from an empty string. Bind it to NIL if
you would rather have NULL collapse into NIL.")

(defun default-column-name-transformer (name)
  "Return NAME, a PostgreSQL column name, as an upper-case keyword with
underscores read as hyphens."
  (intern (substitute #\- #\_ (string-upcase name)) :keyword))

(defun column-keys (fields)
  "Return a vector of the keys the columns FIELDS will be stored under."
  (let ((transformer (if (functionp *column-name-transformer*)
                         *column-name-transformer*
                         (fdefinition *column-name-transformer*))))
    (map 'simple-vector
         (lambda (field) (funcall transformer (cl-postgres:field-name field)))
         fields)))

;;; ---------------------------------------------------------------------
;;; Row shapes
;;; ---------------------------------------------------------------------

(defun plist-row (keys values)
  "Build a property list from the parallel vectors KEYS and VALUES."
  (loop :for key :across keys
        :for value :across values
        :collect key
        :collect value))

(defun alist-row (keys values)
  "Build an association list from the parallel vectors KEYS and VALUES."
  (map 'list #'cons keys values))

(defun hash-table-row (keys values)
  "Build an EQUAL hash table from the parallel vectors KEYS and VALUES."
  (let ((table (make-hash-table :test #'equal :size (max 1 (length keys)))))
    (map nil (lambda (key value) (setf (gethash key table) value)) keys values)
    table))

(defun list-row (keys values)
  "Return the column values of one row as a list, ignoring KEYS."
  (declare (ignore keys))
  (coerce values 'list))

(defun vector-row (keys values)
  "Return the column values of one row as a vector, ignoring KEYS."
  (declare (ignore keys))
  values)

(defun value-row (keys values)
  "Return the single column value of one row, ignoring KEYS."
  (declare (ignore keys))
  (aref values 0))

(defun struct-constructor (name)
  "Return the default constructor function for the structure class NAME."
  (let ((constructor (find-symbol (concatenate 'string "MAKE-" (symbol-name name))
                                  (symbol-package name))))
    (unless (and constructor (fboundp constructor))
      (error "No constructor MAKE-~a found for structure ~s. Pass the constructor
explicitly as (:struct ~s <constructor>)."
             (symbol-name name) name name))
    (fdefinition constructor)))

(defun row-mapper (format)
  "Return the function of (KEYS VALUES) that builds one row in FORMAT.

FORMAT is one of

  :PLIST       (:id 1 :user-name \"alice\")          -- the default
  :ALIST       ((:id . 1) (:user-name . \"alice\"))
  :HASH-TABLE  an EQUAL hash table keyed the same way
  :LIST        (1 \"alice\")
  :VECTOR      #(1 \"alice\")
  :VALUE       the single column's value; several columns is an error
  (:CLASS name)            MAKE-INSTANCE with the column keys as initargs
  (:STRUCT name)           MAKE-name with the column keys as keyword arguments
  (:STRUCT name function)  as above with an explicit constructor
  a function or function name, called with the key vector and the value vector

:CLASS needs no metaobject protocol: the column keys are simply passed to
MAKE-INSTANCE, so the class has to declare an :INITARG for each column selected."
  (cond
    ((functionp format) format)
    ((keywordp format)
     (ecase format
       (:plist #'plist-row)
       (:alist #'alist-row)
       (:hash-table #'hash-table-row)
       (:list #'list-row)
       (:vector #'vector-row)
       (:value #'value-row)))
    ((consp format)
     (destructuring-bind (kind name &optional constructor) format
       (ecase kind
         (:class (lambda (keys values)
                   (apply #'make-instance name (plist-row keys values))))
         (:struct (let ((build (cond ((functionp constructor) constructor)
                                     (constructor (fdefinition constructor))
                                     (t (struct-constructor name)))))
                    (lambda (keys values)
                      (apply build (plist-row keys values))))))))
    ((and (symbolp format) (fboundp format)) (fdefinition format))
    (t (error "~s is not a row format. See the documentation of ROW-MAPPER." format))))

;;; ---------------------------------------------------------------------
;;; Row readers
;;; ---------------------------------------------------------------------
;;;
;;; The collecting and the streaming reader are written out separately rather
;;; than sharing a helper: NEXT-ROW and NEXT-FIELD are local functions
;;; established by CL-POSTGRES:ROW-READER, so anything factored out of the body
;;; would have to be a macro, and the macro would be longer than the ten lines
;;; it saves.
;;;
;;; Draining has to read the fields, not just the rows. NEXT-ROW stops after the
;;; DataRow header and leaves the field data in the socket for NEXT-FIELD, so a
;;; drain loop that only called NEXT-ROW would read field bytes as if they were
;;; the next message header and desynchronise the connection it was trying to
;;; rescue.

(defun check-single-column (fields sql)
  "Signal TOO-MANY-COLUMNS-ERROR unless FIELDS describes exactly one column."
  (unless (= 1 (length fields))
    (error 'too-many-columns-error :sql sql :column-count (length fields))))

(defun make-collecting-row-reader (format sql)
  "Return a cl-postgres row reader collecting the whole result as a list of rows
built in FORMAT. SQL is carried only so that errors can report it."
  (let ((mapper (row-mapper format))
        (single-column (eq format :value))
        (null-value *null-value*))
    (cl-postgres:row-reader (fields)
      (let ((keys (column-keys fields))
            (width (length fields))
            (finished nil)
            (rows '()))
        (unwind-protect
             (progn
               (when single-column (check-single-column fields sql))
               (loop :while (next-row)
                     :do (let ((values (make-array width)))
                           (dotimes (index width)
                             (let ((value (next-field (aref fields index))))
                               (setf (aref values index)
                                     (if (eq value :null) null-value value))))
                           (push (funcall mapper keys values) rows)))
               (setf finished t))
          (unless finished
            (loop :while (next-row)
                  :do (dotimes (index width) (next-field (aref fields index))))))
        (nreverse rows)))))

(defun make-streaming-row-reader (format sql function)
  "Return a cl-postgres row reader calling FUNCTION with each row built in
FORMAT, and returning the number of rows read. SQL is carried only so that
errors can report it."
  (let ((mapper (row-mapper format))
        (single-column (eq format :value))
        (null-value *null-value*))
    (cl-postgres:row-reader (fields)
      (let ((keys (column-keys fields))
            (width (length fields))
            (finished nil)
            (count 0))
        (unwind-protect
             (progn
               (when single-column (check-single-column fields sql))
               (loop :while (next-row)
                     :do (let ((values (make-array width)))
                           (dotimes (index width)
                             (let ((value (next-field (aref fields index))))
                               (setf (aref values index)
                                     (if (eq value :null) null-value value))))
                           (funcall function (funcall mapper keys values))
                           (incf count)))
               (setf finished t))
          (unless finished
            (loop :while (next-row)
                  :do (dotimes (index width) (next-field (aref fields index))))))
        count))))
