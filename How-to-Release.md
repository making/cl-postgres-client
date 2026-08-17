# How to Release

Quicklisp tracks this project as `latest-github-release`: every dist build asks
GitHub for the repository's newest release and takes the source tarball GitHub
generated for its tag. A release is therefore the only thing that reaches
Quicklisp users -- a commit on the default branch does not, and neither does a
tag that no release object points at.

Two consequences worth keeping in mind:

- **Never publish a prerelease.** The controller takes the first entry of the
  releases list, which includes prereleases. A `v0.2.0-rc1` published for a
  handful of testers would go out to everyone.
- **Nothing is uploaded.** GitHub's automatic source tarball is what gets
  fetched, so the tag has to be a state that builds on its own.

Nothing has been released yet: `v0.1.0` will be the first tag, and the project
is not registered with Quicklisp until that release exists.

## Before cutting one

- CI is green on `develop` -- SBCL, CCL and ECL, plus rontolisp's three
  backends. Quicklisp builds on SBCL, but a library it distributes is expected
  to be portable, and CCL and ECL are what keep that claim honest.
- Both systems in `cl-postgres-client.asd` load without a database. Quicklisp
  loads every system a `.asd` defines, `cl-postgres-client/test` included, so
  anything needing a live PostgreSQL must stay inside a test body rather than
  run at load time. Check it the way the dist build would:

  ```sh
  sbcl --non-interactive --no-userinit \
       --load .quicklisp/setup.lisp \
       --eval '(push (truename ".") asdf:*central-registry*)' \
       --eval '(ql:quickload "cl-postgres-client")' \
       --eval '(ql:quickload "cl-postgres-client/test")'
  ```

- Every exported symbol carries a docstring, `src/package.lisp`'s `:export`
  list still groups them by concern, and README covers what is new.

## Cutting one

Versions are semantic, and 0.x means the surface may still move: breaking
changes bump the minor, everything else the patch.

`:version` is bumped here and nowhere else. It is not touched as features land
on `develop`; it is set in its own commit as step 1 below, and the tag goes on
that very commit. Between releases the file therefore names the version that
was last published, which is what a caller loading the checkout gets told.

1. Make `:version` in **both** systems in `cl-postgres-client.asd` the version
   being released -- nothing updates them for you. For the first release the
   file already says `0.1.0`. CI checks the two against the tag in step 3 and
   fails the run if they disagree, so a stale version costs a deleted tag
   rather than a bad dist.
2. Commit any change from step 1 and let CI finish on `develop`.
3. Tag that commit and push the tag:

   ```sh
   git tag -a v0.1.0 -m "Release 0.1.0"
   git push origin v0.1.0
   ```

4. Publish the release -- `--generate-notes` writes the commit log since the
   previous tag, which is the point of an annotated history:

   ```sh
   gh release create v0.1.0 --title v0.1.0 --generate-notes
   ```

5. Confirm the tarball Quicklisp will fetch really carries the system at its
   top level:

   ```sh
   curl -sSL "$(gh release view v0.1.0 --json tarballUrl -q .tarballUrl)" \
     | tar tz | grep -E '\.asd$'
   ```

6. Move `main` to the released commit, so the branch always names the last
   published state:

   ```sh
   git push origin v0.1.0^{}:main
   ```

## Registering with Quicklisp -- first release only

Open an issue at <https://github.com/quicklisp/quicklisp-projects/issues>.
Pull requests are explicitly not accepted there.

```
Title: Add cl-postgres-client

Project: cl-postgres-client
Source: https://github.com/making/cl-postgres-client (MIT)
Please track: latest-github-release

A high-level PostgreSQL client for Common Lisp layered on cl-postgres and
shaped after Spring Framework's JdbcClient. It adds named parameters (:name in
SQL), row mapping to plists / alists / hash tables / CLOS instances / structs,
transactions with savepoints and isolation levels, result streaming, COPY and
LISTEN/NOTIFY, reachable either through one-line functions or a fluent
statement builder. cl-postgres is the only runtime dependency.

Documentation: https://github.com/making/cl-postgres-client#readme
```

The maintainer adds `projects/cl-postgres-client/source.txt` containing

```
latest-github-release https://github.com/making/cl-postgres-client.git
```

and the project appears in the next dist, which is built roughly monthly. A
build failure comes back as a comment on that issue.

Once it has landed, README's install section changes from "put the repository
where ASDF can find it" to `(ql:quickload "cl-postgres-client")`.

## After registration

Nothing per release: the next dist build picks up whatever the newest release
is. To confirm a version landed:

```lisp
(ql:update-dist "quicklisp")
(ql:system-apropos "cl-postgres-client")
```
