# cl-postgres-client

A high-level PostgreSQL client for Common Lisp, layered on
[cl-postgres](https://github.com/marijnh/Postmodern/tree/master/cl-postgres) and
shaped after Spring Framework's `JdbcClient`: named parameters, row mapping,
transactions with savepoints, streaming, COPY and LISTEN/NOTIFY, reachable
either through one-line functions or a fluent statement builder.

cl-postgres is the only runtime dependency.

## Install

Put the repository where ASDF can find it and load it:

```lisp
(asdf:load-system "cl-postgres-client")
```

The package is `postgres-client`, nicknamed `pgc`. SBCL is the supported
implementation; see [rontolisp](#rontolisp) for the other one that runs it.

## Use

```lisp
(pgc:with-client (client :host "localhost" :port 5432
                         :database "app" :user "app" :password "secret")

  (pgc:query-list client "select id, name from users where age > :age"
                  :params '(:age 20))
  ; => ((:id 1 :name "alice") (:id 2 :name "bob"))

  (pgc:query-single client "select id, name from users where id = :id"
                    :params '(:id 1))          ; => (:id 1 :name "alice")
  (pgc:query-optional client "select id from users where id = :id"
                      :params '(:id 99))       ; => NIL
  (pgc:query-value client "select count(*) from users")          ; => 42
  (pgc:query-column client "select name from users order by id") ; => ("alice" ...)

  (pgc:update client "insert into users (name) values (:name)"
              :params '(:name "carol"))        ; => 1

  (pgc:with-transaction (client :isolation :serializable)
    (pgc:update client "update accounts set balance = balance - :n where id = :from"
                :params '(:n 100 :from 1))
    (pgc:update client "update accounts set balance = balance + :n where id = :to"
                :params '(:n 100 :to 2))))
```

The same operations compose as a pipeline when the statement is built up rather
than written out:

```lisp
(pgc:-> (pgc:sql client "select age from customer where id = :id")
        (pgc:param :id 3)
        (pgc:query :as :value)
        (pgc:optional))                        ; => 42
```

A statement is immutable, so `param` returns a copy and one base can be finished
many ways.

## Named parameters

`:name` placeholders are rewritten to PostgreSQL's `$1`, `$2` before the
statement is prepared. Names are matched case- and underscore-insensitively, so
SQL stays snake_case while Lisp stays kebab-case:

```lisp
(pgc:query-value client "select id from users where user_name = :user_name"
                 :params '(:user-name "alice"))
```

The rewriting is done by a scanner, not by search and replace, so a colon inside
a string literal, a dollar-quoted body, a quoted identifier, a comment, a
`::cast`, a `:=` assignment or an array slice is left alone.

`?` is **not** a placeholder — in PostgreSQL it is a jsonb and geometry operator
(`data ? 'key'`). For positional parameters write `$1` yourself and pass a plain
list:

```lisp
(pgc:query-value client "select name from users where id = $1 and age = $2"
                 :params '(2 20))
```

`params` reads its argument according to the SQL: a statement with named
placeholders takes a property list, an association list or a hash table; one with
`$n` placeholders takes a sequence of values.

## Row formats

`:as` chooses the shape of a row. The default is `*default-row-format*`, which
starts out as `:plist`.

| `:as` | a row of `select id, user_name ...` |
| --- | --- |
| `:plist` | `(:id 1 :user-name "alice")` |
| `:alist` | `((:id . 1) (:user-name . "alice"))` |
| `:hash-table` | an `equal` hash table keyed the same way |
| `:list` | `(1 "alice")` |
| `:vector` | `#(1 "alice")` |
| `:value` | `1` — several columns is an error |
| `(:class name)` | `(make-instance 'name :id 1 :user-name "alice")` |
| `(:struct name)` | `(make-name :id 1 :user-name "alice")` |
| a function | called with the key vector and the value vector |

Column names are converted by `*column-name-transformer*`, which by default
reads snake_case as an upper-case kebab-case keyword. `(:class ...)` needs no
metaobject protocol: the keys are passed to `make-instance`, so the class has to
declare an `:initarg` for each column selected.

A SQL `NULL` reads as `:null`, which is what cl-postgres itself produces and
keeps `NULL` apart from a false boolean. Bind `*null-value*` to `nil` to collapse
the two. In the other direction, pass `:null` to write a `NULL` — a Lisp `nil`
is sent as `false`.

## Transactions

```lisp
(pgc:with-transaction (client :isolation :repeatable-read :read-only t)
  ...)
```

Committing on normal exit, rolling back on any non-local exit. A nested
`with-transaction` becomes a savepoint, since PostgreSQL has no nested
transactions; `isolation`, `read-only` and `deferrable` apply to a whole
transaction and are an error on a nested one rather than a silent no-op.

`(pgc:rollback-only client)` discards the innermost scope's work while letting
the body run to the end. A `rollback` restart is established around the body.

## Streaming

`do-rows` hands over one row at a time, so the result never has to fit in
memory. Leaving early is safe — the rest of the result is drained before the
connection is handed back:

```lisp
(pgc:do-rows (row client "select id, name from users" :as :list)
  (when (equal (second row) "bob") (return row)))
```

`map-rows` and `fold-rows` are the functional forms.

## Bulk loading

```lisp
(pgc:copy-rows client "users" '((1 "alice") (2 "bob")) :columns '("id" "name"))
```

`copy-rows` uses the COPY protocol and runs in a transaction, so an error part
way through leaves the table as it was. `with-copy-writer` and `copy-write-row`
are the incremental form.

## Notifications

```lisp
(pgc:listen-channel listener "events")
(pgc:notify sender "events" "payload")
(pgc:wait-for-notification listener)  ; => "events", "payload", 12345
```

`wait-for-notification` blocks and occupies its connection, so a program that
also runs queries needs a second client for listening.

## Errors

Anything the server rejects arrives as `cl-postgres:database-error`, unwrapped,
with `pgc:database-error-code` (SQLSTATE), `-message`, `-detail`, `-query` and
`-constraint-name` re-exported for convenience. cl-postgres's specific classes,
such as `cl-postgres-error:unique-violation`, still match.

What this library signals itself is the mismatch between what was asked for and
what came back: `empty-result-error`, `too-many-rows-error`,
`too-many-columns-error`, `parameter-error` and `transaction-error`, all under
`postgres-client-error`.

## Prepared statements

Every parameterised statement is prepared and cached on its connection, keyed by
SQL text, and reused — `batch-update` in particular prepares once and executes
per parameter set. The cache is bounded by `*statement-cache-size*` so that
dynamically built SQL cannot leak backend memory, and a statement the server has
forgotten is prepared again automatically. `clear-statement-cache` empties it by
hand after a schema change.

A statement with no parameters goes over the simple query protocol instead,
which is what lets `execute` run the utility commands — `SET`, `VACUUM`, most of
DDL — that cannot be prepared at all.

## Threads

A client is not thread safe; making it so would mean a locking dependency. Give
each thread its own client. There is no connection pool.

## Develop

```sh
make test      # start PostgreSQL in Docker, then run the suite
make db-down   # stop it again
```

`make test` installs a project-local Quicklisp under `.quicklisp/` on first run,
so nothing has to be installed beyond SBCL and Docker. The suite runs against
`postgres:17-alpine` on port 55432; point it elsewhere with `PGC_TEST_HOST`,
`PGC_TEST_PORT`, `PGC_TEST_DB`, `PGC_TEST_USER` and `PGC_TEST_PASSWORD`.

The container authenticates with `md5` rather than the modern `scram-sha-256`.
Nothing here tests authentication, and SCRAM costs 4096 rounds of PBKDF2 per
connection -- half a minute per test on an interpreter, where every test opens
its own connection.

## rontolisp

The library also runs on [rontolisp](https://github.com/making/rontolisp), a
Common Lisp subset with an interpreter, a JVM compiler and two WebAssembly
compilers. Nothing is conditionalised for it: the same sources load through
`asdf:load-system` and the whole public API answers as it does on SBCL.

```sh
make rontolisp-test        # interpreter
make rontolisp-test-jvm    # compiled to JVM bytecode
make rontolisp-test-wasm   # compiled to a WASI 0.3 component
```

rontolisp's ASDF does not fall back to Quicklisp for a missing dependency, so
these targets pre-fetch `cl-postgres` and `rove` into rontolisp's own cache and
name every release directory on `--system-path`; the Makefile does both.
WebAssembly Preview 1 is out by design -- it has no TCP sockets -- so the
component is the only WASM target.

The suite is not yet green there. What fails is the test framework's recorder
meeting rontolisp's condition handling, not the library: prepared-statement
recovery (which catches its own error and retries), `do-rows`' early `return` on
the interpreter, and a handful of `signals` assertions. The details, per backend,
are in rontolisp's own `.todo/408`.

## License

MIT. See [LICENSE](LICENSE).
