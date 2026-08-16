;;;; src/package.lisp
;;;;
;;;; The library's single public package.  Everything a user needs lives here;
;;;; there is no second "internals" package, because the escape hatch to the
;;;; layer below is cl-postgres itself, not a private corner of this one.
;;;;
;;;; The error accessors are imported from cl-postgres and re-exported rather
;;;; than wrapped: a PostgreSQL error is a PostgreSQL error, and hiding it
;;;; behind a parallel condition hierarchy would only cost the caller its
;;;; SQLSTATE.

(defpackage #:postgres-client
  (:nicknames #:pgc)
  (:use #:cl)
  ;; NEXT-ROW and NEXT-FIELD are the local functions CL-POSTGRES:ROW-READER
  ;; establishes around its body. The macro expands to an FLET of the symbols in
  ;; the CL-POSTGRES package, so a row reader written here has to use those very
  ;; symbols rather than same-named ones of its own.
  (:import-from #:cl-postgres
                #:next-row
                #:next-field
                #:database-error
                #:database-error-message
                #:database-error-detail
                #:database-error-code
                #:database-error-query
                #:database-error-constraint-name)
  (:export
   ;; Connecting
   #:connect
   #:disconnect
   #:reconnect
   #:connected-p
   #:with-client
   #:wrap-connection
   #:client
   #:client-p
   #:client-connection
   #:clear-statement-cache

   ;; Fluent statement building
   #:->
   #:sql
   #:param
   #:params

   ;; Fluent terminal operations
   #:query
   #:update
   #:execute
   #:rows
   #:single
   #:optional
   #:value
   #:column

   ;; One-line convenience forms
   #:query-list
   #:query-single
   #:query-optional
   #:query-value
   #:query-column
   #:batch-update

   ;; Streaming
   #:do-rows
   #:map-rows
   #:fold-rows

   ;; Transactions
   #:with-transaction
   #:with-savepoint
   #:rollback-only
   ;; Name of the restart WITH-TRANSACTION and WITH-SAVEPOINT establish, not a
   ;; function: (invoke-restart 'pgc:rollback)
   #:rollback
   #:in-transaction-p
   #:transaction-depth

   ;; Bulk copying
   #:copy-rows
   #:with-copy-writer
   #:copy-write-row

   ;; Asynchronous notification
   #:listen-channel
   #:unlisten-channel
   #:notify
   #:wait-for-notification

   ;; Configuration
   #:*default-row-format*
   #:*column-name-transformer*
   #:*null-value*
   #:*statement-cache-size*

   ;; SQL utilities
   #:parse-named-parameters
   #:quote-identifier

   ;; Conditions raised by this library
   #:postgres-client-error
   #:empty-result-error
   #:too-many-rows-error
   #:too-many-columns-error
   #:parameter-error
   #:transaction-error
   #:error-sql
   #:error-row-count
   #:error-column-count
   #:error-parameter-name
   #:error-description

   ;; Conditions raised by PostgreSQL, re-exported from cl-postgres
   #:database-error
   #:database-error-message
   #:database-error-detail
   #:database-error-code
   #:database-error-query
   #:database-error-constraint-name))
