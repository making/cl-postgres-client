# 1. Align the users-fixture cleanup with CAUGHT-CONDITION

Difficulty: Low

`t/helpers.lisp`'s `with-users` still drops its table under `ignore-errors`:

```lisp
(unwind-protect (progn ,@body)
  (ignore-errors (pgc:execute ,client "drop table if exists users")))
```

Every other in-test catch moved to `caught-condition` when the suite grew its
rontolisp runs; this one was missed. Nothing fails because of it today -- the
drop does not error -- so it is a consistency item, not a bug.

## Why it is worth doing anyway

`ignore-errors` expands to `handler-case`, and a test framework's recorder can
see the condition before the clause swallows it (rontolisp `.todo/393`; on SBCL
it is invisible). The day the drop DOES fail -- a leftover lock, a connection
already gone -- the suite would report "Raise an error while testing." against
whichever test happened to be finishing, naming neither the fixture nor the real
cause. `caught-condition` catches with `handler-bind` and a named block, so the
condition never reaches an outer handler.

## The work

Replace the `ignore-errors` with `caught-condition`, which is already defined a
few lines above it in the same file. One line, no behaviour change on SBCL.
