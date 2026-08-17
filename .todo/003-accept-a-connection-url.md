# 3. Accept a connection URL

Difficulty: Medium

`connect` only takes the pieces:

```lisp
(pgc:connect :host "db.internal" :port 5432 :database "app"
             :user "app" :password "secret")
```

Everything that hands out PostgreSQL credentials -- Heroku, Fly, Supabase,
Docker Compose, a Kubernetes secret, `DATABASE_URL` in any twelve-factor app --
hands them out as one string instead:

```
postgresql://app:secret@db.internal:5432/app?sslmode=require
```

Today the caller has to take that string apart before this library will look at
it, which is precisely the part they would rather not write.

## The shape to aim for

`connect` gains a `:url` keyword, and `with-client` inherits it for free
because it passes its options straight through:

```lisp
(pgc:with-client (client :url (uiop:getenv "DATABASE_URL"))
  ...)
```

Decisions worth making deliberately rather than by accident:

- **Explicit keywords next to `:url`.** Either they override what the URL says
  or they are an error. Overriding reads better -- `:url url :application-name
  "importer"` is a real use -- but only if the precedence is documented in the
  docstring rather than left to be discovered.
- **Export the parser too.** A caller who wants the pieces for something else
  (logging the host without the password, say) should not have to re-implement
  it. Something like `parse-connection-url` returning the plist `connect`
  accepts, so `(apply #'pgc:connect (pgc:parse-connection-url url))` is the
  same thing spelled out.
- **A bad URL signals a condition of this library's own**, not whatever the
  parser happened to hit. `src/conditions.lisp` is where its siblings live.

## What the parser actually has to handle

This is the part that will take the time. libpq's own accepted forms, in the
order they will bite:

- Both `postgresql://` and `postgres://` schemes.
- Percent-encoding, and in the password especially: `p%40ssword` is `p@ssword`,
  and a naive `position #\@` finds the wrong `@`. Decode after splitting, and
  split on the *last* `@` in the authority.
- Every component optional: `postgresql:///app` is the local socket-or-host
  default with database `app`; `postgresql://localhost` has no database at all
  and must be rejected the way a missing `:database` already is.
- IPv6 literals in brackets -- `postgresql://[::1]:5432/app` -- where the colons
  inside the brackets are not the port separator.
- Query parameters. `sslmode` is the one that matters, and its libpq values do
  not match this library's `use-ssl` values one for one: `disable` `allow`
  `prefer` `require` `verify-ca` `verify-full` against `:no` `:try` `:require`
  `:yes` `:full`. Map them explicitly and document the mapping.
  `application_name` maps straight through. An unknown parameter should not be
  silently dropped.
- `postgresql:///app?host=/var/run/postgresql` -- the Unix socket form, which
  this library spells `:host :unix`.

No new dependency. cl-postgres is the only runtime dependency this library
has, so this is hand-written string work: no quri, no cl-ppcre. It also has to
stay conditionalisation-free and keep running on rontolisp's three backends, so
check the operators used against what rontolisp actually provides before
leaning on them.

## Tests

`t/connection-url-test.lisp`. The parsing half needs no database at all, so add
it to the list of such files `CLAUDE.md` keeps. Cover at least: both schemes, a
percent-encoded password containing
`@` and `:`, a missing port, a missing database, an IPv6 literal, each
`sslmode` value, an unknown query parameter, and something that is not a URL at
all. Then one test that actually connects through a URL built from the fixture
settings, so the plist really is what `connect` wants.

## Documentation

README's install/use section gets the `DATABASE_URL` form -- it is the first
thing most readers will look for -- and `src/package.lisp` gains the new
exports under the "Connecting" group.

## When this is done

The release that follows is the project's first, and
[How-to-Release.md](../How-to-Release.md) is written to be read on its own:
work through it top to bottom and it ends with the Quicklisp registration
issue.
