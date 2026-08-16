LISP ?= sbcl
QUICKLISP_URL ?= https://beta.quicklisp.org/quicklisp.lisp

.PHONY: test deps db-up db-down db-logs repl clean

## Run the whole suite against a freshly started PostgreSQL container.
test: deps db-up
	$(LISP) --script run-tests.lisp

## Install a project-local Quicklisp. Skipped when one is already present.
deps: .quicklisp/setup.lisp

.quicklisp/setup.lisp:
	@set -eu; \
	tmp="$$(mktemp -d)"; \
	trap 'rm -rf "$$tmp"' EXIT; \
	curl -sSLo "$$tmp/quicklisp.lisp" "$(QUICKLISP_URL)"; \
	$(LISP) --non-interactive --no-userinit \
	        --load "$$tmp/quicklisp.lisp" \
	        --eval '(quicklisp-quickstart:install :path ".quicklisp/")'

db-up:
	docker compose up -d --wait

db-down:
	docker compose down -v

db-logs:
	docker compose logs -f postgres

## REPL with the system loaded and the source registry pointed at this checkout.
repl: deps
	$(LISP) --load .quicklisp/setup.lisp \
	        --eval '(asdf:initialize-source-registry (list :source-registry (list :tree (uiop:getcwd)) :inherit-configuration))' \
	        --eval '(ql:quickload "cl-postgres-client")'

## Drop the compiled output, which ASDF keeps outside the checkout.
clean:
	find . -name '*.fasl' -delete
	$(LISP) --non-interactive --no-userinit \
	        --eval '(require :asdf)' \
	        --eval '(uiop:delete-directory-tree (asdf:apply-output-translations (uiop:getcwd)) :validate t :if-does-not-exist :ignore)'
