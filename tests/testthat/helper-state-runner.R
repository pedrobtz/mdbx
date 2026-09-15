# The state-machine runner: generate a sequence of public API calls, run each
# against both the package and the reference model in helper-state-model.R, and
# compare the whole observable state after every step.
#
# Why this exists, in one line: the focused tests were green while the bugs the
# reviews found were live, because each feature was tested alone and the
# failures lived in the cross products -- a panic *and* a live transaction, a
# forged handle *and* an idempotent entry point, a damaged record *and* a
# native convention that reads character(0) as "the main database".
#
# Two rules keep it honest:
#
#   * Invariants are checked after refusals as well as successes. A command
#     that fails must change nothing, and the transaction must still work
#     afterwards. That is the check that catches a call returning a plausible
#     value from the wrong database.
#   * Everything is reproducible from a seed, and a failure prints the trace
#     that produced it. Nothing here depends on test file order.
#
# Every failure this finds should become an ordinary named test. A seed is a
# way to discover a bug, not a way to guard one.

# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------

# The generated alphabet, kept small on purpose: a handful of keys collide
# often enough to exercise overwrite, delete-existing and refused-overwrite
# rather than writing a thousand distinct keys once each.
state_keys <- function() {
  c(list(raw(0)), lapply(0:5, function(i) as.raw(c(0x6b, i))), list(as.raw(0x6b)))
}

state_values <- function() {
  c(list(raw(0)), lapply(1:4, function(i) as.raw(rep(i, i))))
}

state_db_names <- function() c("d1", "d2", "d3")

# Spellings of one path that all denote the same environment, plus a second,
# genuinely different path.
#
# This dimension exists because a bug lived in it: keying the open registry by
# the path as written meant `./x` and `x` were two environments, and asserting
# `subdir = TRUE` over an existing single-file database made a third key for
# the same file.
state_paths <- function(dir) {
  single <- file.path(dir, "one.mdbx")
  list(
    list(id = "one", path = single, subdir = FALSE),
    list(id = "one", path = file.path(dir, ".", "one.mdbx"), subdir = FALSE),
    list(id = "one", path = single, subdir = TRUE),
    list(id = "two", path = file.path(dir, "two.mdbx"), subdir = FALSE)
  )
}

new_state_fixture <- function(map_size = 4 * 1024^2, max_dbs = 8L) {
  dir <- tempfile("state-")
  dir.create(dir)

  # Settle whatever the rest of the suite abandoned to the collector before
  # taking a baseline: local_env() never closes explicitly, so the registry
  # carries other tests' environments until their finalizers run. Twice,
  # because one pass does not always reach everything.
  gc()
  gc()

  # `envs` and `live` are environments, so the handles they hold live in
  # exactly one place however many copies of this list get passed around.
  # A plain `fixture_txn(fixture)` field was copied into every returned step, and
  # cleanup could then only drop its own copy -- leaving the transaction
  # object reachable, and its finalizer unrun, long after the sequence ended.
  list(
    dir = dir,
    map_size = map_size,
    max_dbs = max_dbs,
    env_baseline = mdbx:::mdbx_env_open_count_(),
    envs = new.env(parent = emptyenv()),
    live = new.env(parent = emptyenv())
  )
}

# The transaction the sequence currently holds, or NULL.
fixture_txn <- function(fixture) {
  if (exists("txn", envir = fixture$live, inherits = FALSE)) {
    get("txn", envir = fixture$live)
  } else {
    NULL
  }
}

set_fixture_txn <- function(fixture, txn) {
  if (is.null(txn)) {
    if (exists("txn", envir = fixture$live, inherits = FALSE)) {
      rm("txn", envir = fixture$live)
    }
  } else {
    assign("txn", txn, envir = fixture$live)
  }
  invisible(fixture)
}

# Close whatever the sequence left open, tolerating handles that a panic or an
# earlier failure already finished. Registered immediately after the fixture is
# built, so a failed assertion cannot skip it.
clean_state_fixture <- function(fixture) {
  txn <- fixture_txn(fixture)
  try(if (!is.null(txn)) mdbx_txn_abort(txn), silent = TRUE)

  # Drop the references as well as ending the handles, so the objects are
  # collectable as soon as the sequence is over rather than whenever the last
  # frame that saw them happens to die.
  set_fixture_txn(fixture, NULL)
  rm(txn)

  for (label in ls(fixture$envs)) {
    try(mdbx_env_close(get(label, envir = fixture$envs)), silent = TRUE)
  }
  rm(list = ls(fixture$envs), envir = fixture$envs)

  unlink(fixture$dir, recursive = TRUE)
}

# ---------------------------------------------------------------------------
# Outcome capture
# ---------------------------------------------------------------------------

# Normalise a call into data so the model can be compared against it without
# the comparison caring how R signalled the result.
capture_outcome <- function(code) {
  tryCatch(
    list(ok = TRUE, value = force(code)),
    error = function(error) {
      list(
        ok = FALSE,
        classes = class(error),
        message = conditionMessage(error),
        code = error$code,
        name = error$name
      )
    }
  )
}

outcome_label <- function(outcome) {
  if (isTRUE(outcome$ok)) {
    return(paste("ok:", paste(format(outcome$value)[1], collapse = "")))
  }
  paste0("error<", paste(setdiff(outcome$classes, c("error", "condition")),
                         collapse = "/"), ">: ", outcome$message)
}

# ---------------------------------------------------------------------------
# Failure reporting
# ---------------------------------------------------------------------------

format_command <- function(command) {
  args <- command[setdiff(names(command), "op")]
  rendered <- vapply(names(args), function(name) {
    value <- args[[name]]
    sprintf("%s = %s", name, paste(deparse(value), collapse = ""))
  }, "")
  sprintf("%s(%s)", command$op, paste(rendered, collapse = ", "))
}

format_trace <- function(trace) {
  paste(sprintf("  %2d. %s", seq_along(trace), vapply(trace, format_command, "")),
        collapse = "\n")
}

state_failure <- function(profile, seed, step, trace, invariant, detail) {
  stop(sprintf(paste0(
    "mdbx state-machine mismatch\n",
    "profile:   %s\n",
    "seed:      %d\n",
    "step:      %d/%d\n",
    "invariant: %s\n",
    "detail:    %s\n",
    "trace:\n%s\n"),
    profile, seed, step, length(trace), invariant, detail, format_trace(trace)),
    call. = FALSE)
}

# ---------------------------------------------------------------------------
# Generation
# ---------------------------------------------------------------------------

pick <- function(x) x[[sample.int(length(x), 1L)]]

# Which commands make sense in this state. Preconditions keep the sequence
# productive: generating `put` with no transaction open would only ever assert
# the same refusal.
available_ops <- function(fixture, model, profile) {
  open_labels <- ls(fixture$envs)
  ops <- character(0)

  if (length(open_labels) < 3L) ops <- c(ops, rep("open_env", 3L))
  if (length(open_labels) > 0L && is.null(fixture_txn(fixture))) {
    ops <- c(ops, "close_env", rep("begin", 6L))
  }

  if (!is.null(fixture_txn(fixture))) {
    ops <- c(ops, rep(c("get", "keys", "items"), 2L), "state", "commit", "abort",
             "dbi_list", "dbi_open", "stat")
    if (isTRUE(model$txn$write)) {
      ops <- c(ops, rep(c("put", "del"), 3L), "dbi_create", "dbi_drop", "sequence")
    } else {
      # Refusals are generated deliberately: the no-change invariant after one
      # is worth as much as the success path.
      ops <- c(ops, "put_readonly", "dbi_create_readonly")
    }
  }

  if (identical(profile, "adversarial")) {
    ops <- c(ops, if (!is.null(fixture_txn(fixture))) c("bad_dbi", "bad_arg") else "forged_handle")
  }

  ops
}

generate_command <- function(fixture, model, profile) {
  op <- pick(available_ops(fixture, model, profile))
  db <- if (!is.null(fixture_txn(fixture))) pick(c("main", visible_dbs(model$txn$view))) else "main"

  switch(op,
    open_env = {
      spelling <- pick(state_paths(fixture$dir))
      # A free label: reassigning one in use would drop the only reference to
      # an environment that is still open, and nothing could then close it.
      free <- setdiff(paste0("e", 1:3), ls(fixture$envs))
      list(op = "open_env", label = pick(as.list(free)),
           id = spelling$id, path = spelling$path, subdir = spelling$subdir)
    },
    close_env = list(op = "close_env", label = pick(ls(fixture$envs))),
    begin = list(op = "begin", label = pick(ls(fixture$envs)),
                 write = sample(c(TRUE, FALSE), 1L)),
    get = list(op = "get", db = db, key = raw_id(pick(state_keys()))),
    put = ,
    put_readonly = list(op = op, db = db, key = raw_id(pick(state_keys())),
                        value = raw_id(pick(state_values())),
                        overwrite = sample(c(TRUE, FALSE), 1L)),
    del = list(op = "del", db = db, key = raw_id(pick(state_keys()))),
    keys = ,
    items = list(op = op, db = db,
                 limit = pick(list(NULL, 1L, 3L, 100L)),
                 start = pick(c(list(NULL), lapply(state_keys(), raw_id))),
                 reverse = sample(c(TRUE, FALSE), 1L)),
    dbi_open = list(op = "dbi_open", name = pick(state_db_names())),
    dbi_create = ,
    dbi_create_readonly = list(op = op, name = pick(state_db_names())),
    dbi_drop = list(op = "dbi_drop", name = pick(c(state_db_names(),
                                                   visible_dbs(model$txn$view))),
                    delete = sample(c(TRUE, FALSE), 1L)),
    stat = list(op = "stat", db = db),
    sequence = list(op = "sequence", db = db,
                    increment = pick(list(0, 1, 5))),
    bad_dbi = list(op = "bad_dbi", db = db,
                   field = pick(c("name", "path", "token")),
                   value = pick(list(character(0), "", NA_character_,
                                     c("a", "b"), NULL, 42))),
    bad_arg = list(op = "bad_arg", which = pick(c("dots", "flag", "limit", "class"))),
    forged_handle = list(op = "forged_handle",
                         which = pick(c("txn_state", "txn_abort", "txn_get",
                                        "env_stat", "env_close", "env_is_open"))),
    list(op = op)
  )
}

# ---------------------------------------------------------------------------
# Execution: run the command, update the model, and say what both did
# ---------------------------------------------------------------------------

# The `db` argument as the public API takes it: NULL for the main database.
db_handle <- function(fixture, db) {
  if (is.null(db) || identical(db, "main")) NULL else mdbx_dbi_open(fixture_txn(fixture), db)
}

run_command <- function(fixture, model, command) {
  op <- command$op

  if (op == "open_env") {
    already <- model_env_is_open(model, command$id)
    outcome <- capture_outcome(
      mdbx_env_open(command$path, subdir = command$subdir,
                    max_dbs = fixture$max_dbs, map_size = fixture$map_size)
    )

    # Stored before the outcome is judged, not after. An open that succeeds
    # where the model expected a refusal is a failure -- but the handle it
    # returned is real, and clean_state_fixture() can only close what it can
    # reach through fixture$envs. Returning first left a second libmdbx
    # environment open on the same file for the rest of the session, so every
    # later test touching that path inherited the damage instead of seeing the
    # one clean failure here.
    if (isTRUE(outcome$ok)) {
      assign(command$label, outcome$value, envir = fixture$envs)
    }

    if (already) {
      # Every spelling of an environment this process already has open must be
      # refused, and refused by name rather than with the lock file's errno.
      return(list(model = model, fixture = fixture, outcome = outcome,
                  expect = "error", must_match = "already open in this process"))
    }

    if (isTRUE(outcome$ok)) {
      model <- model_open_env(model, command$label, command$id)
    }
    return(list(model = model, fixture = fixture, outcome = outcome, expect = "ok"))
  }

  if (op == "close_env") {
    outcome <- capture_outcome(mdbx_env_close(get(command$label, envir = fixture$envs)))
    rm(list = command$label, envir = fixture$envs)
    model <- model_close_env(model, command$label)
    return(list(model = model, fixture = fixture, outcome = outcome, expect = "ok"))
  }

  if (op == "begin") {
    outcome <- capture_outcome(
      mdbx_txn_begin(get(command$label, envir = fixture$envs), write = command$write))
    if (isTRUE(outcome$ok)) {
      set_fixture_txn(fixture, outcome$value)
      model <- model_begin(model, model_denotes(model, command$label), command$write)
    }
    return(list(model = model, fixture = fixture, outcome = outcome, expect = "ok"))
  }

  if (op == "commit" || op == "abort") {
    outcome <- capture_outcome(
      if (op == "commit") mdbx_txn_commit(fixture_txn(fixture)) else mdbx_txn_abort(fixture_txn(fixture)))
    model <- if (op == "commit") model_commit(model) else model_abort(model)
    set_fixture_txn(fixture, NULL)
    return(list(model = model, fixture = fixture, outcome = outcome, expect = "ok"))
  }

  if (op == "state") {
    outcome <- capture_outcome(mdbx_txn_state(fixture_txn(fixture)))
    return(list(model = model, fixture = fixture, outcome = outcome, expect = "ok",
                equals = "active"))
  }

  if (op == "stat") {
    outcome <- capture_outcome(mdbx_env_stat(fixture_txn(fixture), db = db_handle(fixture, command$db)))
    return(list(model = model, fixture = fixture, outcome = outcome, expect = "ok"))
  }

  if (op == "get") {
    expected <- store_db(model$txn$view, command$db)[[command$key]]
    outcome <- capture_outcome(
      mdbx_get(fixture_txn(fixture), id_raw(command$key), as = "raw",
               db = db_handle(fixture, command$db)))
    return(list(model = model, fixture = fixture, outcome = outcome, expect = "ok",
                equals = expected))
  }

  if (op == "put") {
    step <- model_put(model, command$db, command$key, id_raw(command$value),
                      command$overwrite)
    outcome <- capture_outcome(
      mdbx_put(fixture_txn(fixture), id_raw(command$key), id_raw(command$value),
               overwrite = command$overwrite, db = db_handle(fixture, command$db)))
    return(list(model = step$model, fixture = fixture, outcome = outcome,
                expect = "ok", equals = step$stored))
  }

  if (op == "del") {
    step <- model_del(model, command$db, command$key)
    outcome <- capture_outcome(
      mdbx_del(fixture_txn(fixture), id_raw(command$key), db = db_handle(fixture, command$db)))
    return(list(model = step$model, fixture = fixture, outcome = outcome,
                expect = "ok", equals = step$deleted))
  }

  if (op == "keys" || op == "items") {
    expected <- expected_keys(model$txn$view, command$db, limit = command$limit,
                              start = command$start, reverse = command$reverse)
    got <- capture_outcome(
      if (op == "keys") {
        mdbx_keys(fixture_txn(fixture), limit = command$limit, as = "raw",
                  db = db_handle(fixture, command$db),
                  start = if (is.null(command$start)) NULL else id_raw(command$start),
                  reverse = command$reverse)
      } else {
        mdbx_items(fixture_txn(fixture), limit = command$limit, as = "raw", keys_as = "raw",
                   db = db_handle(fixture, command$db),
                   start = if (is.null(command$start)) NULL else id_raw(command$start),
                   reverse = command$reverse)$keys
      })
    if (isTRUE(got$ok)) got$value <- vapply(got$value, raw_id, "")
    return(list(model = model, fixture = fixture, outcome = got, expect = "ok",
                equals = expected))
  }

  if (op == "dbi_list") {
    outcome <- capture_outcome(mdbx_dbi_list(fixture_txn(fixture)))
    if (isTRUE(outcome$ok)) outcome$value <- sort(outcome$value, method = "radix")
    return(list(model = model, fixture = fixture, outcome = outcome, expect = "ok",
                equals = sort(visible_dbs(model$txn$view), method = "radix")))
  }

  if (op == "dbi_open") {
    exists <- command$name %in% visible_dbs(model$txn$view)
    outcome <- capture_outcome(mdbx_dbi_open(fixture_txn(fixture), command$name))
    return(list(model = model, fixture = fixture, outcome = outcome,
                expect = if (exists) "ok" else "error",
                must_match = if (exists) NULL else "does not exist"))
  }

  if (op == "dbi_create") {
    outcome <- capture_outcome(mdbx_dbi_open(fixture_txn(fixture), command$name, create = TRUE))
    if (isTRUE(outcome$ok)) model <- model_dbi_create(model, command$name)
    return(list(model = model, fixture = fixture, outcome = outcome, expect = "ok"))
  }

  if (op == "dbi_drop") {
    exists <- command$name %in% visible_dbs(model$txn$view)
    outcome <- capture_outcome(
      mdbx_dbi_drop(fixture_txn(fixture), mdbx_dbi_open(fixture_txn(fixture), command$name),
                    delete = command$delete))
    if (exists) model <- model_dbi_drop(model, command$name, command$delete)
    return(list(model = model, fixture = fixture, outcome = outcome,
                expect = if (exists) "ok" else "error",
                must_match = if (exists) NULL else "does not exist"))
  }

  if (op == "sequence") {
    step <- model_sequence(model, command$db, command$increment)
    outcome <- capture_outcome(
      mdbx_dbi_sequence(fixture_txn(fixture), db_handle(fixture, command$db), command$increment))
    return(list(model = step$model, fixture = fixture, outcome = outcome,
                expect = "ok", equals = step$value))
  }

  # --- deliberately refused -------------------------------------------------

  if (op == "put_readonly") {
    outcome <- capture_outcome(
      mdbx_put(fixture_txn(fixture), id_raw(command$key), id_raw(command$value),
               db = db_handle(fixture, command$db)))
    return(list(model = model, fixture = fixture, outcome = outcome,
                expect = "error", must_match = "read-only"))
  }

  if (op == "dbi_create_readonly") {
    outcome <- capture_outcome(mdbx_dbi_open(fixture_txn(fixture), command$name, create = TRUE))
    return(list(model = model, fixture = fixture, outcome = outcome,
                expect = "error", must_match = "needs a write transaction"))
  }

  if (op == "bad_dbi") {
    # Built here rather than obtained from mdbx_dbi_open(), so that damaging a
    # record cannot also create a database the model does not know about -- and
    # so the refusal is provoked by the damage and not by a missing database.
    # The path and token are the transaction's own, so the cross-environment
    # check passes and the field validation is what has to catch this.
    handle <- structure(list(name = "d1",
                             path = attr(fixture_txn(fixture), "path"),
                             token = attr(fixture_txn(fixture), "token")),
                        class = "mdbx_dbi")
    handle[[command$field]] <- command$value
    outcome <- capture_outcome(
      mdbx_get(fixture_txn(fixture), id_raw(raw_id(as.raw(0x6b))), as = "raw", db = handle))
    return(list(model = model, fixture = fixture, outcome = outcome,
                expect = "error", must_match = "not a valid 'mdbx_dbi'"))
  }

  if (op == "bad_arg") {
    outcome <- switch(command$which,
      dots  = capture_outcome(mdbx_env_stat(fixture_txn(fixture), nonsense = 1)),
      flag  = capture_outcome(mdbx_txn_begin(
                get(pick(ls(fixture$envs)), envir = fixture$envs), flags = "NOPE")),
      limit = capture_outcome(mdbx_keys(fixture_txn(fixture), limit = -1)),
      class = capture_outcome(mdbx_get(fixture_txn(fixture), "k", db = "not a handle")))
    return(list(model = model, fixture = fixture, outcome = outcome, expect = "error"))
  }

  if (op == "forged_handle") {
    # Only strangers here. `class<-` on an external pointer modifies it in
    # place -- there is no copy to reclass -- so reclassing a handle the
    # sequence still holds would destroy the fixture rather than test it.
    # Reclassing a genuine environment as a transaction is covered by its own
    # focused test in test-native-safety.R, which builds a handle to spend.
    forged <- methods::new("externalptr")
    class(forged) <- if (startsWith(command$which, "txn")) "mdbx_txn" else "mdbx_env"

    outcome <- switch(command$which,
      txn_state    = capture_outcome(mdbx_txn_state(forged)),
      txn_abort    = capture_outcome(mdbx_txn_abort(forged)),
      txn_get      = capture_outcome(mdbx_get(forged, "k")),
      env_stat     = capture_outcome(mdbx_env_stat(forged)),
      env_close    = capture_outcome(mdbx_env_close(forged)),
      env_is_open  = capture_outcome(mdbx_env_is_open(forged)))

    expected <- if (startsWith(command$which, "txn")) {
      "expected an 'mdbx_txn' object"
    } else {
      "expected an 'mdbx_env' object"
    }
    return(list(model = model, fixture = fixture, outcome = outcome,
                expect = "error", must_match = expected))
  }

  stop("unhandled command in the state-machine runner: ", op)
}

# ---------------------------------------------------------------------------
# Invariants, checked after every command -- refused ones included
# ---------------------------------------------------------------------------

# The observable contents of every database in the current view, read back
# through the public API. Compared against the model byte for byte.
observe_databases <- function(fixture, model) {
  if (is.null(fixture_txn(fixture))) {
    return(NULL)
  }

  dbs <- c("main", visible_dbs(model$txn$view))
  stats::setNames(lapply(dbs, function(db) {
    handle <- if (identical(db, "main")) NULL else mdbx_dbi_open(fixture_txn(fixture), db)
    items <- mdbx_items(fixture_txn(fixture), as = "raw", keys_as = "raw", db = handle)
    ids <- vapply(items$keys, raw_id, "")
    stats::setNames(items$values, ids)
  }), dbs)
}

expected_databases <- function(model) {
  view <- model$txn$view
  dbs <- c("main", visible_dbs(view))
  stats::setNames(lapply(dbs, function(db) {
    contents <- store_db(view, db)
    # A named database is a key of main, so a listing of main includes the
    # names; the value is libmdbx's own record, which the model does not model.
    if (identical(db, "main")) {
      for (name in visible_dbs(view)) contents[[raw_id(charToRaw(name))]] <- NULL
    }
    contents[sorted_ids(names(contents))]
  }), dbs)
}

# Compare what the package holds with what the model says it should, ignoring
# the libmdbx-owned bytes stored against a named database's own key in main.
check_data_invariant <- function(fixture, model, fail) {
  observed <- observe_databases(fixture, model)
  if (is.null(observed)) {
    return(invisible(NULL))
  }
  expected <- expected_databases(model)

  for (db in names(expected)) {
    want <- expected[[db]]
    got <- observed[[db]]
    got <- got[setdiff(names(got), vapply(visible_dbs(model$txn$view),
                                          function(n) raw_id(charToRaw(n)), ""))]
    got <- got[sorted_ids(names(got))]

    # An empty list's names() is NULL, not character(0); normalise so an empty
    # database on both sides compares equal.
    want_names <- if (is.null(names(want))) character(0) else names(want)
    got_names <- if (is.null(names(got))) character(0) else names(got)

    if (!identical(want_names, got_names)) {
      fail("committed data matches the model",
           sprintf("database %s: model has {%s}, package has {%s}", db,
                   paste(want_names, collapse = ","),
                   paste(got_names, collapse = ",")))
    }
    for (key in names(want)) {
      if (!identical(as.raw(want[[key]]), as.raw(got[[key]]))) {
        fail("stored values match the model",
             sprintf("database %s key %s: model %s, package %s", db, key,
                     raw_id(want[[key]]), raw_id(got[[key]])))
      }
    }
  }
  invisible(NULL)
}

# Handles and registry entries the package is holding, which must track what
# the sequence actually has open.
check_lifecycle_invariant <- function(fixture, model, fail) {
  open_labels <- ls(fixture$envs)

  # An upper bound, not an equality. The baseline is a snapshot of a
  # process-wide count, and the rest of the suite leaves environments for the
  # collector: one of those being finalized part-way through a sequence lowers
  # the count under a baseline taken before it ran, and an equality test then
  # fails pointing at this sequence rather than at the unrelated finalizer that
  # actually moved. The sequence's own handles are all strongly referenced in
  # fixture$envs and cannot be collected, so nothing of ours goes missing.
  #
  # A leak -- an environment this sequence opened and lost track of -- can only
  # push the count up, so the bound that matters is still checked. Each handle's
  # own state is verified below.
  held <- mdbx:::mdbx_env_open_count_() - fixture$env_baseline
  if (held > length(open_labels)) {
    fail("the open registry holds no environment this sequence lost track of",
         sprintf("registry grew by %d, the sequence holds %d",
                 held, length(open_labels)))
  }

  for (label in open_labels) {
    handle <- get(label, envir = fixture$envs)
    if (!mdbx_env_is_open(handle)) {
      fail("an environment the sequence holds reports itself open", label)
    }
    expected_txns <- if (!is.null(fixture_txn(fixture)) &&
                         identical(model_denotes(model, label), model$txn$env)) 1L else 0L
    if (!identical(mdbx:::mdbx_env_txn_count_(handle), expected_txns)) {
      fail("at most one transaction is registered per environment",
           sprintf("%s: registry says %d, expected %d", label,
                   mdbx:::mdbx_env_txn_count_(handle), expected_txns))
    }
  }

  if (!is.null(fixture_txn(fixture)) && !identical(mdbx_txn_state(fixture_txn(fixture)), "active")) {
    fail("a live transaction reports itself usable",
         sprintf("state is %s", mdbx_txn_state(fixture_txn(fixture))))
  }
  invisible(NULL)
}

# A refused command must leave the transaction working. This is the check that
# distinguishes "refused" from "refused after doing half of it".
check_usable_after_refusal <- function(fixture, fail) {
  if (is.null(fixture_txn(fixture))) {
    return(invisible(NULL))
  }
  probe <- capture_outcome(mdbx_get(fixture_txn(fixture), as.raw(c(0x7a, 0x7a)), as = "raw"))
  if (!isTRUE(probe$ok)) {
    fail("the transaction still works after a refusal", outcome_label(probe))
  }
  invisible(NULL)
}

# ---------------------------------------------------------------------------
# The driver
# ---------------------------------------------------------------------------

check_outcome <- function(step, command, fail) {
  outcome <- step$outcome

  if (identical(step$expect, "error")) {
    if (isTRUE(outcome$ok)) {
      fail("a command the contract refuses must fail",
           sprintf("%s returned %s", format_command(command), outcome_label(outcome)))
    }
    if (!is.null(step$must_match) &&
        !grepl(step$must_match, outcome$message, fixed = TRUE)) {
      fail("the refusal names the actual conflict",
           sprintf("expected %s, got: %s", dQuote(step$must_match), outcome$message))
    }
    return(invisible(NULL))
  }

  if (!isTRUE(outcome$ok)) {
    fail("a command the contract allows must succeed",
         sprintf("%s failed: %s", format_command(command), outcome_label(outcome)))
  }

  if ("equals" %in% names(step)) {
    want <- step$equals
    got <- outcome$value
    if (is.list(want) || is.list(got)) {
      want <- if (is.null(want)) NULL else as.raw(unlist(want))
      got <- if (is.null(got)) NULL else as.raw(unlist(got))
    }
    if (!identical(want, got)) {
      fail("the value matches the model",
           sprintf("model %s, package %s",
                   paste(format(want), collapse = ","),
                   paste(format(got), collapse = ",")))
    }
  }
  invisible(NULL)
}

run_mdbx_sequence <- function(seed, steps = 60L, profile = "core", fixture = NULL) {
  set.seed(seed)

  owned <- is.null(fixture)
  if (owned) fixture <- new_state_fixture()
  model <- new_mdbx_model()
  trace <- list()

  if (owned) on.exit(clean_state_fixture(fixture), add = TRUE)

  for (step_index in seq_len(steps)) {
    command <- generate_command(fixture, model, profile)
    trace[[step_index]] <- command

    fail <- function(invariant, detail) {
      state_failure(profile, seed, step_index, trace, invariant, detail)
    }

    step <- run_command(fixture, model, command)
    fixture <- step$fixture
    model <- step$model

    check_outcome(step, command, fail)
    if (identical(step$expect, "error")) check_usable_after_refusal(fixture, fail)
    check_lifecycle_invariant(fixture, model, fail)
    check_data_invariant(fixture, model, fail)
  }

  invisible(trace)
}

# ---------------------------------------------------------------------------
# Phase 3: fault injection
#
# A libmdbx assertion failure is terminal -- it poisons the environment, and
# nothing may touch it again -- so these are short, deliberately fatal traces
# rather than commands mixed into a long sequence. What varies is the shape of
# the approach and the order of the cleanup, because that is where the bug was:
# abort refused a poisoned graph, close refused while the transaction was still
# registered, and the refusal raised from on.exit() replaced the panic itself.
#
# The panics come from the package's own internal hooks. There is no way to
# provoke a libmdbx assertion through the public API, which is exactly why
# eight inconsistent poison callbacks survived a green suite.
# ---------------------------------------------------------------------------

fault_plans <- function() {
  list(
    list(id = "env-panic, txn then env",  panic = "env", live_txn = TRUE,  order = "txn"),
    list(id = "env-panic, env then txn",  panic = "env", live_txn = TRUE,  order = "env"),
    list(id = "env-panic, no txn",        panic = "env", live_txn = FALSE, order = "env"),
    list(id = "txn-panic, txn then env",  panic = "txn", live_txn = TRUE,  order = "txn"),
    list(id = "txn-panic, env then txn",  panic = "txn", live_txn = TRUE,  order = "env"),
    list(id = "with_read wrapping panic", panic = "wrapped", live_txn = FALSE, order = "env")
  )
}

# Run one fault plan and assert the whole blast radius, not just the immediate
# error. `expect` is testthat's expect_true and friends, passed in so this stays
# usable from a plain script while the test file drives it.
run_mdbx_fault <- function(plan, gc_first = FALSE) {
  fail <- function(invariant, detail) {
    stop(sprintf(paste0(
      "mdbx fault-injection mismatch\n",
      "plan:      %s\n",
      "gc first:  %s\n",
      "invariant: %s\n",
      "detail:    %s\n"), plan$id, gc_first, invariant, detail), call. = FALSE)
  }

  gc()
  txns_before <- mdbx:::mdbx_txn_live_count_()
  envs_before <- mdbx:::mdbx_env_open_count_()

  env <- mdbx_env_open(tempfile(fileext = ".mdbx"), map_size = 4 * 1024^2, max_dbs = 4L)
  txn <- if (plan$live_txn) mdbx_txn_begin(env, write = TRUE) else NULL

  # Registered before anything can fail, so a mismatch cannot leave a live
  # handle behind for the next plan to trip over.
  on.exit({
    try(if (!is.null(txn)) mdbx_txn_abort(txn), silent = TRUE)
    try(mdbx_env_close(env), silent = TRUE)
  }, add = TRUE)

  # The panic, and the condition the caller actually sees.
  observed <- switch(plan$panic,
    env     = capture_outcome(mdbx:::mdbx_test_panic_stat_(env, FALSE)),
    txn     = capture_outcome(mdbx:::mdbx_test_panic_get_(txn)),
    wrapped = capture_outcome(
      mdbx_with_read(env, function(t) mdbx:::mdbx_test_panic_stat_(env, FALSE))))

  if (isTRUE(observed$ok)) {
    fail("injecting a panic raises a condition", "the call returned normally")
  }

  # The original panic must survive its own cleanup. mdbx_with_*() abort from
  # on.exit(), and while abort refused a poisoned graph that refusal replaced
  # the assertion message -- destroying the only account of what libmdbx found.
  if (!grepl("libmdbx assertion failed", observed$message, fixed = TRUE)) {
    fail("the original panic survives cleanup",
         sprintf("surfaced instead: %s", observed$message))
  }

  # Poison reaches the environment whichever operation tripped it.
  if (mdbx_env_is_open(env)) {
    fail("a panic poisons the environment", "mdbx_env_is_open() is still TRUE")
  }
  if (plan$live_txn && !identical(mdbx_txn_state(txn), "poisoned")) {
    fail("a panic poisons the live transaction",
         sprintf("state is %s", mdbx_txn_state(txn)))
  }

  if (gc_first) gc()

  # Cleanup, in the generated order. Neither call may refuse, and neither may
  # re-enter libmdbx: refusing is what once made a panic unrecoverable without
  # dropping every reference and forcing a collection.
  cleanup <- function(what) {
    outcome <- switch(what,
      txn = if (plan$live_txn) capture_outcome(mdbx_txn_abort(txn)) else list(ok = TRUE),
      env = capture_outcome(mdbx_env_close(env)))
    if (!isTRUE(outcome$ok)) {
      fail(sprintf("%s cleanup after a panic succeeds", what), outcome$message)
    }
  }

  if (identical(plan$order, "txn")) {
    cleanup("txn"); cleanup("env")
  } else {
    cleanup("env"); cleanup("txn")
  }

  # Idempotent afterwards, and stable once the finalizers have run.
  cleanup("txn"); cleanup("env")
  if (plan$live_txn && !identical(mdbx_txn_state(txn), "aborted")) {
    fail("a cleaned-up transaction reads as ended",
         sprintf("state is %s", mdbx_txn_state(txn)))
  }

  rm(env, txn)
  gc()
  gc()

  if (!identical(mdbx:::mdbx_txn_live_count_(), txns_before)) {
    fail("no transaction handle is leaked",
         sprintf("%d before, %d after", txns_before, mdbx:::mdbx_txn_live_count_()))
  }
  if (!identical(mdbx:::mdbx_env_open_count_(), envs_before)) {
    fail("the open registry is empty again",
         sprintf("%d before, %d after", envs_before, mdbx:::mdbx_env_open_count_()))
  }

  invisible(TRUE)
}

# The other lifecycle failure worth generating: a transaction libmdbx has
# marked erroneous. Unlike a panic this is reachable from the public API, so it
# is a natural end to an ordinary sequence rather than an injected fault.
run_mdbx_exhaustion <- function(seed) {
  set.seed(seed)
  fail <- function(invariant, detail) {
    stop(sprintf("mdbx exhaustion mismatch\nseed: %d\ninvariant: %s\ndetail: %s\n",
                 seed, invariant, detail), call. = FALSE)
  }

  env <- mdbx_env_open(tempfile(fileext = ".mdbx"), map_size = 1024^2)
  on.exit({
    try(mdbx_env_close(env), silent = TRUE)
  }, add = TRUE)

  txn <- mdbx_txn_begin(env, write = TRUE)
  mdbx_put(txn, "before", "kept")

  filled <- capture_outcome(mdbx_put(txn, "big", as.raw(rep(1, 4e6))))
  if (isTRUE(filled$ok) || !identical(filled$name, "MDBX_MAP_FULL")) {
    fail("the map fills", outcome_label(filled))
  }

  # State has to describe usability, not allocation: this transaction can do
  # nothing but end, and reporting it as "active" was the original defect.
  if (!identical(mdbx_txn_state(txn), "failed")) {
    fail("an erroneous transaction reports itself failed",
         sprintf("state is %s", mdbx_txn_state(txn)))
  }

  after <- capture_outcome(mdbx_get(txn, "before", as = "raw"))
  if (isTRUE(after$ok) || !identical(after$name, "MDBX_BAD_TXN")) {
    fail("every later operation fails with MDBX_BAD_TXN", outcome_label(after))
  }

  # The commit reports a rollback rather than committing, and nothing written
  # in the transaction survives.
  committed <- capture_outcome(mdbx_txn_commit(txn))
  if (isTRUE(committed$ok)) {
    fail("committing an erroneous transaction is refused", "the commit succeeded")
  }
  if (!identical(mdbx_txn_state(txn), "aborted")) {
    fail("a rolled-back transaction reads as aborted",
         sprintf("state is %s", mdbx_txn_state(txn)))
  }

  survived <- mdbx_with_read(env, function(t) mdbx_get(t, "before"))
  if (!is.null(survived)) {
    fail("a rolled-back transaction writes nothing",
         sprintf("'before' survived as %s", survived))
  }

  invisible(TRUE)
}

# ---------------------------------------------------------------------------
# The corpus the test files drive
#
# In a helper rather than at the top of test-state-machine.R, because a
# definition in an ordinary test file does not exist until that file has been
# sourced -- which under shuffle = TRUE may be after a file that calls it.
# The suite caught this one on its first shuffled run.
# ---------------------------------------------------------------------------

state_machine_seeds <- function() {
  fixed <- c(1L, 17L, 101L, 509L, 1847L, 4099L, 7919L, 12011L, 20260913L, 90210L)

  # A maintainer can explore beyond the fixed corpus without editing the file.
  extra <- Sys.getenv("MDBX_STATE_SEEDS")
  if (nzchar(extra)) {
    fixed <- c(fixed, as.integer(strsplit(extra, ",", fixed = TRUE)[[1]]))
  }
  fixed
}

state_machine_steps <- function(default = 60L) {
  if (identical(tolower(Sys.getenv("MDBX_STATE_MACHINE_STRESS")), "true")) 400L else default
}
