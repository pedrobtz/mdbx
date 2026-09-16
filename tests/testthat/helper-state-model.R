# A reference model of what mdbx is supposed to do.
#
# This is the oracle for the generated sequences in test-state-machine*.R. It
# describes *observable public behaviour* and is written from the documentation
# rather than from the implementation -- which is the whole point. A model
# derived from the binding would encode the binding's bugs into the oracle and
# prove nothing: ?mdbx_dbi_list once described the reverse of what it did, and
# only an independent expectation catches that.
#
# What it deliberately does not model: the text of error messages. Statuses are
# compared by class, `code` and `name` (see ?mdbx-errors), because message
# wording is user-facing prose rather than a machine contract. The focused
# tests remain the guardian of what the messages actually say.

# Keys and values are bytes, so the model stores bytes. A raw vector becomes a
# fixed-width hex string to index a list with.
#
# Two bytes per byte, so lexicographic order over these strings is byte order:
# "6b" < "6b01" both as text and as keys, because libmdbx compares the common
# prefix and then puts the shorter first. Every sort below therefore has to use
# method = "radix", which is C byte order -- the default is locale collation,
# which is not.
# The leading "k" is not decoration: a zero-length key is legal in mdbx and the
# suite stores one, but "" cannot name a list element in R -- indexing by it
# yields an NA-named NULL rather than the value. A constant prefix keeps every
# id usable as a name without disturbing the ordering.
raw_id <- function(x) {
  paste0("k", paste(sprintf("%02x", as.integer(x)), collapse = ""))
}

id_raw <- function(id) {
  hex <- substring(id, 2L)
  if (!nzchar(hex)) {
    return(raw(0))
  }
  as.raw(strtoi(substring(hex, seq(1L, nchar(hex), 2L), seq(2L, nchar(hex), 2L)), 16L))
}

sorted_ids <- function(ids, reverse = FALSE) {
  out <- sort(as.character(ids), method = "radix")
  if (reverse) rev(out) else out
}

new_mdbx_model <- function() {
  list(
    # Environments this process has open, by label. Each records which
    # environment it *denotes*: the generator builds several spellings of one
    # path, so two labels can name the same database. That is the model's own
    # knowledge, by construction, not a re-derivation of env_data_file().
    envs = list(),
    committed = list(),
    txn = NULL
  )
}

new_store <- function() {
  list(main = list(), named = list(), sequences = list(main = 0))
}

# The database a command addresses, as the model indexes it.
store_db <- function(store, db) {
  if (identical(db, "main")) store$main else store$named[[db]]
}

set_store_db <- function(store, db, value) {
  if (identical(db, "main")) {
    store$main <- value
  } else {
    store$named[[db]] <- value
  }
  store
}

# The view a command reads and writes: a write transaction's private working
# copy, a read transaction's snapshot, or the committed state.
model_view <- function(model, env) {
  if (!is.null(model$txn) && identical(model$txn$env, env)) {
    return(model$txn$view)
  }
  model$committed[[env]]
}

# Named databases visible to the current view. Creation shows immediately in
# the transaction that made it, deletion disappears immediately, and the commit
# or abort decides what anyone else sees.
visible_dbs <- function(view) {
  sorted_names <- names(view$named)
  if (is.null(sorted_names)) character(0) else sorted_names
}

# What mdbx_keys() should return for a database, as hex ids in byte order.
#
# libmdbx stores named databases as keys of the main database, so a listing of
# main includes their names. That is the storage layout showing through rather
# than a leak, and the model has to account for it or every scan of main
# disagrees.
expected_keys <- function(view, db, limit = NULL, start = NULL, reverse = FALSE) {
  ids <- names(store_db(view, db))
  if (is.null(ids)) ids <- character(0)

  if (identical(db, "main")) {
    ids <- c(ids, vapply(visible_dbs(view), function(n) raw_id(charToRaw(n)), ""))
  }

  ids <- sorted_ids(unique(ids), reverse = reverse)

  # `start` is inclusive, and positions the cursor at the first key at or after
  # it going forwards, or at or before it going backwards.
  #
  # Compared by position in a radix ordering, never with <= or >= on the strings
  # themselves. Those are collation comparisons -- the very thing sorted_ids()
  # uses method = "radix" to avoid -- while libmdbx positions the cursor by raw
  # byte order. Under a collation that orders the hex ids differently the oracle
  # and the package would disagree about a scan neither got wrong, and under one
  # that happens to agree it would hide the day they really did.
  if (!is.null(start)) {
    ordered <- sort(unique(c(ids, start)), method = "radix")
    at <- match(start, ordered)
    pos <- match(ids, ordered)
    keep <- if (reverse) pos <= at else pos >= at
    ids <- ids[keep]
  }

  if (!is.null(limit) && is.finite(limit) && length(ids) > limit) {
    ids <- ids[seq_len(limit)]
  }

  ids
}

# ---------------------------------------------------------------------------
# Transitions. Each returns the model as it should be after the command.
# ---------------------------------------------------------------------------

model_open_env <- function(model, label, denotes) {
  model$envs[[label]] <- list(denotes = denotes, state = "open")
  if (is.null(model$committed[[denotes]])) {
    model$committed[[denotes]] <- new_store()
  }
  model
}

model_close_env <- function(model, label) {
  model$envs[[label]] <- NULL
  model
}

# The environment a label denotes, or NULL when nothing has that label open.
model_denotes <- function(model, label) {
  entry <- model$envs[[label]]
  if (is.null(entry)) NULL else entry$denotes
}

# Is some open label already denoting this environment?
model_env_is_open <- function(model, denotes) {
  any(vapply(model$envs, function(e) identical(e$denotes, denotes), logical(1)))
}

model_begin <- function(model, env, write) {
  model$txn <- list(
    env = env,
    write = write,
    state = "active",
    view = model$committed[[env]]
  )
  model
}

model_commit <- function(model) {
  if (isTRUE(model$txn$write)) {
    model$committed[[model$txn$env]] <- model$txn$view
  }
  model$txn <- NULL
  model
}

model_abort <- function(model) {
  model$txn <- NULL
  model
}

model_put <- function(model, db, key, value, overwrite) {
  view <- model$txn$view
  target <- store_db(view, db)
  existed <- !is.null(target[[key]])

  if (existed && !overwrite) {
    return(list(model = model, stored = FALSE))
  }

  target[[key]] <- value
  model$txn$view <- set_store_db(view, db, target)
  list(model = model, stored = TRUE)
}

model_del <- function(model, db, key) {
  view <- model$txn$view
  target <- store_db(view, db)
  existed <- !is.null(target[[key]])

  target[[key]] <- NULL
  model$txn$view <- set_store_db(view, db, target)
  list(model = model, deleted = existed)
}

model_dbi_create <- function(model, name) {
  view <- model$txn$view
  if (is.null(view$named[[name]])) {
    view$named[[name]] <- list()
    view$sequences[[name]] <- 0
  }
  model$txn$view <- view
  model
}

model_dbi_drop <- function(model, name, delete) {
  view <- model$txn$view
  if (delete) {
    view$named[[name]] <- NULL
    view$sequences[[name]] <- NULL
  } else {
    # Emptying a database that holds records resets its sequence counter too:
    # libmdbx rewrites the database's record, and the counter lives in it.
    # Emptying an already-empty one rewrites nothing and leaves it. The
    # generated sequences found this; ?mdbx_dbi_drop now says so.
    if (length(view$named[[name]]) > 0L) {
      view$sequences[[name]] <- 0
    }
    view$named[[name]] <- list()
  }
  model$txn$view <- view
  model
}

model_sequence <- function(model, db, increment) {
  view <- model$txn$view
  current <- view$sequences[[db]]
  if (is.null(current)) current <- 0

  if (increment > 0) {
    view$sequences[[db]] <- current + increment
    model$txn$view <- view
  }

  list(model = model, value = current)
}
