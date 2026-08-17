# CLAUDE.md

Public API, usage and design rationale: [README.md](README.md).
Every source file opens with a `;;;;` banner saying why it exists — read that first.

## Working here

- SBCL is the reference. There is no global Quicklisp/Roswell/qlot on this machine;
  `make deps` installs one under `.quicklisp/`. `make test` needs Docker.
- Every exported symbol must carry a docstring; keep the `:export` list in
  `src/package.lisp` grouped by concern.
- The sources must stay conditionalisation-free: `make rontolisp-test{,-jvm,-wasm}`
  runs the same files on rontolisp's backends, all three are green and all three
  gate CI. Anything they cannot do is reported to making/rontolisp, not worked
  around here.

## cl-postgres facts that cost time to rediscover

Source is under `.quicklisp/dists/quicklisp/software/postmodern-*/cl-postgres/`.

- `row-reader` expands to an `flet` of `cl-postgres::next-row` / `next-field`, so a
  row reader written elsewhere must import those symbols, not define its own.
- `next-row` stops after the DataRow header. Any loop over rows — including a drain
  loop — must also call `next-field` once per column or the connection desynchronises.
- Affected-row count is the *second* value of `exec-query` / `exec-prepared`.
- `prepare-query` with the name `""` is the unnamed statement; parsed statements
  survive `ROLLBACK` (unlike the SQL `PREPARE` command), so the cache needs no
  invalidation on rollback.
- `close-db-writer :abort t` closes the whole *connection*, not just the copy.
- `to-sql-string`: `nil` is `false`, `:null` is SQL NULL.

## Tests

rove, one package (`cl-postgres-client/test`), fixtures in `t/helpers.lisp`.
Assertions are `(ok (signals form 'type))` — `signals` is not an assertion by itself.
`t/named-parameters-test.lisp` and `t/package-test.lisp` are the files that run
without a database.
A test that needs the condition object uses `caught-condition`, not `handler-case`:
a clause that never runs takes its assertions with it and the test passes vacuously.
