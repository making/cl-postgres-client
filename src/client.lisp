;;;; src/client.lisp
;;;;
;;;; The client: one connection plus the state that has to travel with it.
;;;;
;;;; Prepared statements and transaction depth are per-connection facts, so they
;;;; live here rather than in a special variable.  Passing the client explicitly
;;;; is also what keeps a future connection pool possible without changing a
;;;; single call site.
;;;;
;;;; A client is NOT thread safe.  Making it so would mean a lock, and a lock
;;;; would mean a dependency on bordeaux-threads; cl-postgres is the only
;;;; runtime dependency this library is willing to have.  Give each thread its
;;;; own client.

(in-package #:postgres-client)

(defvar *statement-cache-size* 256
  "How many prepared statements a client keeps alive on its connection.
When the cache would grow past this, it is emptied wholesale -- statements are
deallocated on the server too -- and refilled. The bound matters for programs
that build SQL text dynamically, where an unbounded cache would leak backend
memory one statement at a time.")

;;; The slot accessors are %-prefixed and the two public ones are written out
;;; below, so that what a caller may reach for is exactly what is documented.

(defstruct (client (:constructor %make-client)
                   (:copier nil)
                   (:conc-name %client-)
                   (:predicate %client-p))
  "A PostgreSQL connection together with its prepared-statement cache and
transaction state. Create one with CONNECT or WRAP-CONNECTION."
  (connection nil)
  (statement-cache (make-hash-table :test #'equal) :type hash-table)
  (parse-cache (make-hash-table :test #'equal) :type hash-table)
  (statement-counter 0 :type unsigned-byte)
  (transaction-depth 0 :type unsigned-byte)
  (savepoint-counter 0 :type unsigned-byte)
  (rollback-only nil))

(defun client-p (object)
  "True when OBJECT is a client."
  (%client-p object))

(defun client-connection (client)
  "The CL-POSTGRES:DATABASE-CONNECTION underneath CLIENT.
The escape hatch to the layer below, for the occasions this library does not
cover. Take care not to leave a query half read on it."
  (%client-connection client))

(defun required-argument (name)
  "Signal that the keyword argument NAME has to be supplied."
  (error "~s is required." name))

(defun wrap-connection (connection)
  "Return a client for CONNECTION, an existing CL-POSTGRES:DATABASE-CONNECTION.
Use this to put this library's API on top of a connection some other code owns.
Note that DISCONNECT will close it."
  (%make-client :connection connection))

(defun connect (&key url host port database user password use-ssl service
                     application-name use-binary)
  "Open a connection to PostgreSQL and return a client for it.

DATABASE and USER are required, whether given directly or through URL.
HOST defaults to \"localhost\" and may also be :UNIX for a Unix domain socket,
PORT to 5432, PASSWORD to the empty string, USE-SSL to :NO, SERVICE to
\"postgres\" and APPLICATION-NAME to \"cl-postgres-client\". USE-SSL is one of
:NO, :TRY, :REQUIRE, :YES or :FULL, and anything but :NO needs cl+ssl loaded.
The arguments are passed straight through to CL-POSTGRES:OPEN-DATABASE.

URL is a connection URL -- what DATABASE_URL holds:

    (pgc:connect :url \"postgresql://app:secret@db.internal:5432/app\")

Any other argument given beside it wins over what the URL says, so
:URL url :APPLICATION-NAME \"importer\" names the connection without touching
the credentials. PARSE-CONNECTION-URL describes the form in full.

Close the client with DISCONNECT, or use WITH-CLIENT to do so automatically."
  (let ((from-url (when url (parse-connection-url url))))
    (wrap-connection
     (cl-postgres:open-database
      (or database (getf from-url :database) (required-argument :database))
      (or user (getf from-url :user) (required-argument :user))
      (or password (getf from-url :password) "")
      (or host (getf from-url :host) "localhost")
      (or port (getf from-url :port) 5432)
      (or use-ssl (getf from-url :use-ssl) :no)
      (or service "postgres")
      (or application-name (getf from-url :application-name) "cl-postgres-client")
      use-binary))))

(defun connected-p (client)
  "True when CLIENT's connection is currently open."
  (let ((connection (%client-connection client)))
    (and connection (cl-postgres:database-open-p connection))))

(defun forget-statements (client)
  "Drop CLIENT's record of its prepared statements without touching the server.
Used when the connection is gone and there is nothing left to deallocate."
  (clrhash (%client-statement-cache client))
  (values))

(defun clear-statement-cache (client)
  "Deallocate every statement CLIENT has prepared and empty its cache.
Called automatically when the cache reaches *STATEMENT-CACHE-SIZE*; call it
yourself after a schema change that would invalidate cached plans."
  (let ((connection (%client-connection client)))
    (when (and connection (cl-postgres:database-open-p connection))
      (maphash (lambda (sql name)
                 (declare (ignore sql))
                 (ignore-errors (cl-postgres:unprepare-query connection name)))
               (%client-statement-cache client))))
  (forget-statements client))

(defun disconnect (client)
  "Close CLIENT's connection. Doing so to an already closed client is harmless."
  (let ((connection (%client-connection client)))
    (when (and connection (cl-postgres:database-open-p connection))
      (cl-postgres:close-database connection)))
  (forget-statements client)
  (setf (%client-transaction-depth client) 0
        (%client-rollback-only client) nil)
  (values))

(defun reconnect (client)
  "Re-establish CLIENT's connection, discarding prepared statements.
The server has forgotten them, so the cache has to forget them too."
  (forget-statements client)
  (setf (%client-transaction-depth client) 0
        (%client-rollback-only client) nil)
  (cl-postgres:reopen-database (%client-connection client))
  client)

(defmacro with-client ((variable &rest options) &body body)
  "Bind VARIABLE to a client connected with OPTIONS, run BODY, and disconnect.
OPTIONS are CONNECT's keyword arguments.

    (pgc:with-client (client :database \"app\" :user \"app\")
      (pgc:query-value client \"select version()\"))"
  `(let ((,variable (connect ,@options)))
     (unwind-protect (progn ,@body)
       (disconnect ,variable))))
