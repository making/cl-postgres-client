LISP ?= sbcl
QUICKLISP_URL ?= https://beta.quicklisp.org/quicklisp.lisp

# `make test LISP=ecl`, `LISP=ccl`.  What differs between the implementations is
# only how a file is run without an init file and without landing in a REPL:
# SBCL has --script, ECL spells it --shell, and CCL's kernel has neither -- it
# takes --load together with the flags that mean no init file, no herald, and
# exit at end of input.  --load and --eval agree everywhere, so every other line
# below is written once.  A batch of --eval forms still ends with an explicit
# quit, or ECL would fall into the REPL and read make's own stdin.
LISP_KIND = $(notdir $(LISP))
ifeq ($(LISP_KIND),ecl)
  LISP_SCRIPT = --norc --shell
  LISP_BATCH  = --norc
else ifeq ($(LISP_KIND),ccl)
  LISP_SCRIPT = --no-init --quiet --batch --load
  LISP_BATCH  = --no-init --quiet --batch
else
  LISP_SCRIPT = --script
  LISP_BATCH  = --non-interactive --no-userinit
endif

RONTOLISP ?= rontolisp
RONTOLISP_HOME ?= $(HOME)/.rontolisp
BUILD ?= $(CURDIR)/build

# rontolisp's ASDF looks for NAME.asd in flat directories only, and it does not
# fall back to Quicklisp for a missing dependency, so every downloaded release
# has to be named on the search path. The rontolisp-deps target fills the cache.
#
# The list is built by the shell rather than with $(wildcard): those directories
# appear during this same make run, and make would answer from the listing it
# read before the download.
RONTOLISP_SYSTEM_PATH = "$(CURDIR)$$(for dir in $(RONTOLISP_HOME)/quicklisp/software/*/; do printf ':%s' "$$dir"; done)"
RONTOLISP_TEST = $(RONTOLISP) test cl-postgres-client/test --system-path $(RONTOLISP_SYSTEM_PATH)

.PHONY: test deps db-up db-down db-logs repl clean
.PHONY: rontolisp-deps rontolisp-test rontolisp-test-jvm rontolisp-test-wasm

## Run the whole suite against a freshly started PostgreSQL container.
test: deps db-up
	$(LISP) $(LISP_SCRIPT) run-tests.lisp

## Install a project-local Quicklisp. Skipped when one is already present.
deps: .quicklisp/setup.lisp

.quicklisp/setup.lisp:
	@set -eu; \
	tmp="$$(mktemp -d)"; \
	trap 'rm -rf "$$tmp"' EXIT; \
	curl -sSLo "$$tmp/quicklisp.lisp" "$(QUICKLISP_URL)"; \
	printf '(load "%s")(quicklisp-quickstart:install :path "%s")' \
	       "$$tmp/quicklisp.lisp" "$(CURDIR)/.quicklisp/" > "$$tmp/install.lisp"; \
	$(LISP) $(LISP_SCRIPT) "$$tmp/install.lisp"

## Fetch cl-postgres and rove into rontolisp's own Quicklisp cache, which is
## also where the .asd files RONTOLISP_SYSTEM_PATH names come from.
rontolisp-deps:
	$(RONTOLISP) -e '(ql:quickload "cl-postgres")' -e '(ql:quickload "rove")'

## Run the suite on the rontolisp interpreter.
rontolisp-test: rontolisp-deps db-up
	@$(RONTOLISP_TEST)

## Compile the run to JVM bytecode and run it. The class name is the file stem,
## so the artifact has to be written to the directory it is run from.
rontolisp-test-jvm: rontolisp-deps db-up
	@mkdir -p $(BUILD)
	@cd $(BUILD) && $(RONTOLISP_TEST) -o Suite.class && java Suite

## Compile the run to a WASI 0.3 component and run it. The component reaches
## PostgreSQL over the host's network, and by an address rather than a name.
rontolisp-test-wasm: rontolisp-deps db-up
	@mkdir -p $(BUILD)
	@cd $(BUILD) && $(RONTOLISP_TEST) --component -o suite.wasm && \
	  wasmtime run -W gc=y -W exceptions=y -S tcp=y -S inherit-network=y \
	               --env PGC_TEST_HOST=127.0.0.1 suite.wasm

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
	rm -rf $(BUILD)
	$(LISP) $(LISP_BATCH) \
	        --eval '(require :asdf)' \
	        --eval '(uiop:delete-directory-tree (asdf:apply-output-translations (uiop:getcwd)) :validate t :if-does-not-exist :ignore)' \
	        --eval '(uiop:quit)'
