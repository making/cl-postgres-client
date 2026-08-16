# 2. The suite is not green on rontolisp yet -- watch, do not work around

Difficulty: Low (a watch item; the fixes are all in another repository)

`make rontolisp-test{,-jvm,-wasm}` are red, and every failure is in rontolisp's
condition handling meeting rove's recorder rather than in anything here. The
per-backend breakdown lives in making/rontolisp `.todo/408`; the fixes are its
`.todo/393`, `.todo/394`, `.todo/407` and `.todo/409`.

| backend | passed | failed | blocked on |
| --- | --- | --- | --- |
| SBCL (reference) | 186 | 0 | -- |
| rontolisp interpreter | 172 | 14 | 407, 393 |
| rontolisp JVM | 178 | 7 | 207-family, 393 |
| rontolisp WASI component | 165 | 1, then a raw trap | 409, 393 |

CI already reports these counts per backend without blocking, so the day one of
them lands the numbers move on their own. Re-run all three, update the table,
and delete this file when it reaches 186 everywhere.

## The rewrite to NOT do

Two of the failures -- `stale-prepared-statements`, on every backend -- come from
`execute-prepared` catching SQLSTATE 26000 with `handler-case` and re-preparing.
rove's outer `handler-bind` runs anyway there and transfers control, so the retry
never completes.

Rewriting that retry as `handler-bind` + a named block does make it survive, and
this was measured rather than guessed:

```
retrying
  handler-case    x Expect (EQ :OK (WITH-HANDLER-CASE)) to be true.
  handler-bind    v Expect (EQ :OK (WITH-HANDLER-BIND)) to be true.
```

Do not take it. `handler-case` is the clearer form for a catch-and-retry, the
rewrite buys nothing on SBCL, and rontolisp `.todo/393` already names this
library as its sighting -- when it lands, the rewrite is left behind as
complexity with no reason attached. The same reasoning covers the other tempting
edit, putting the test container back on `scram-sha-256`: it would only
re-enact rontolisp `.todo/253` at half a minute per connection.

## What genuinely cannot be fixed here

`t/notification-test.lisp`'s `with-deadline` is `#+sbcl` only, so on rontolisp a
hung `wait-for-notification` would hang the run rather than fail it. There is no
portable way to bound it -- cl-postgres exposes no socket timeout -- so CI's
`timeout-minutes` is the only net. It has never triggered; if it ever does, the
answer is a rontolisp-side timeout, not a conditionalised test.
