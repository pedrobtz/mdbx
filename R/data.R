# Reading and writing.
#
# MDBX stores bytes, so raw vectors are the native currency here. A length-1
# character vector is accepted as a convenience and encoded to its UTF-8 bytes;
# everything else is rejected. Serialization of arbitrary R objects stays the
# caller's job, which is the split design.md asks for.

#' Read a value
#'
#' Looks up `key` in the transaction's snapshot.
#'
#' A key that is not present returns `default` (`NULL` unless you say
#' otherwise). That is unambiguous: a *stored* zero-length value comes back as
#' `raw(0)`, which is not `NULL`, so absence and emptiness stay distinguishable.
#'
#' By default the stored bytes are decoded as UTF-8 text, so a value written as
#' a string comes back as one. MDBX records no type, so this is an assumption
#' rather than something the database knows: **pass `as = "raw"` for any value
#' that is not text**, including anything written with `serialize()`. Decoding
#' raises an error rather than returning something corrupt when the bytes are
#' not valid UTF-8 text, so a wrong assumption is never silent.
#'
#' The returned vector is a copy. 'libmdbx' hands out memory owned by the
#' database, valid only until the transaction ends, so nothing here points into
#' the memory map.
#'
#' @param txn An `mdbx_txn` object, from [mdbx_txn_begin()].
#' @param key A raw vector, or a single string, which is stored as its UTF-8
#'   bytes. The two are interchangeable: `"k"` and `charToRaw("k")` name the
#'   same key. Only raw can express a key containing a NUL byte.
#' @param default Value returned when `key` is absent. It is returned exactly as
#'   given, and is never decoded, whatever `as` is set to.
#' @param as `"character"` (the default) to decode the stored bytes as UTF-8
#'   text, or `"raw"` to return them untouched. Decoding fails, rather than
#'   returning something corrupt, if the value contains a NUL byte or is not
#'   valid UTF-8 — which is what any non-text value will do.
#'
#' @param db An `mdbx_dbi` object from [mdbx_dbi_open()] naming a database to
#'   address instead of the unnamed main one, or `NULL` for the main database.
#' @return A length-1 character vector — or a raw vector if `as = "raw"` — or
#'   `default` if the key is not present.
#' @seealso [mdbx_put()], [mdbx_del()]
#' @export
#' @examples
#' path <- tempfile(fileext = ".mdbx")
#' env <- mdbx_env_open(path)
#'
#' mdbx_with_write(env, function(txn) {
#'   mdbx_put(txn, "answer", "42")
#' })
#'
#' # Decoded as text by default.
#' mdbx_with_read(env, function(txn) {
#'   mdbx_get(txn, "answer")
#' })
#'
#' # Anything that is not text needs as = "raw".
#' mdbx_with_read(env, function(txn) {
#'   mdbx_get(txn, "answer", as = "raw")
#' })
#'
#' mdbx_env_close(env)
#' unlink(c(path, paste0(path, "-lck")))
mdbx_get <- function(txn, key, default = NULL, as = c("character", "raw"),
                     db = NULL) {
  as <- match.arg(as)
  key <- as_bytes(key, "key")

  value <- mdbx_get_(txn, key, db_name(db, txn))

  # `default` is returned as the caller supplied it. Decoding it would be
  # guesswork -- it is an R value, not something that came out of the database.
  if (is.null(value)) {
    return(default)
  }

  if (as == "character") decode_utf8(value) else value
}

# Turn stored bytes back into text, or explain why they are not text.
#
# Marking UTF-8 is required, not decoration: rawToChar() returns a string
# flagged "unknown", meaning the native encoding, so on a non-UTF-8 locale the
# UTF-8 bytes written by mdbx_put() would be reinterpreted and non-ASCII text
# would come back wrong. This is the read-side half of the enc2utf8() call in
# as_bytes().
decode_utf8 <- function(bytes) {
  if (any(bytes == as.raw(0L))) {
    stop(
      'value is not text: it contains a NUL byte. Read it with as = "raw", and ',
      "unserialize() it if it was written with serialize()",
      call. = FALSE
    )
  }

  text <- rawToChar(bytes)

  if (!validUTF8(text)) {
    stop(
      'value is not valid UTF-8 text; read it with as = "raw"',
      call. = FALSE
    )
  }

  Encoding(text) <- "UTF-8"
  text
}

#' Write a value
#'
#' Stores `value` under `key`, replacing any existing value unless `overwrite`
#' is `FALSE`.
#'
#' @param txn An `mdbx_txn` object from [mdbx_txn_begin()], opened with
#'   `write = TRUE`.
#' @param key A raw vector, or a single string, which is stored as its UTF-8
#'   bytes.
#' @param value A raw vector, or a single string, which is stored as its UTF-8
#'   bytes. Use `serialize(x, NULL)` for an arbitrary R object.
#' @param overwrite If `FALSE`, leave an existing value alone and return
#'   `FALSE` instead of replacing it.
#'
#' @param db An `mdbx_dbi` object from [mdbx_dbi_open()] naming a database to
#'   address instead of the unnamed main one, or `NULL` for the main database.
#' @return `TRUE` if the value was stored, `FALSE` if `overwrite = FALSE` and
#'   the key already existed. Returned invisibly.
#' @seealso [mdbx_get()], [mdbx_del()]
#' @export
#' @examples
#' path <- tempfile(fileext = ".mdbx")
#' env <- mdbx_env_open(path)
#'
#' mdbx_with_write(env, function(txn) {
#'   mdbx_put(txn, "k", "first")
#'
#'   # Refuses to replace, and says so.
#'   mdbx_put(txn, "k", "second", overwrite = FALSE)
#' })
#'
#' mdbx_env_close(env)
#' unlink(c(path, paste0(path, "-lck")))
mdbx_put <- function(txn, key, value, overwrite = TRUE, db = NULL) {
  key <- as_bytes(key, "key")
  value <- as_bytes(value, "value")
  overwrite <- check_bool(overwrite, "overwrite")

  invisible(mdbx_put_(txn, key, value, overwrite, db_name(db, txn)))
}

#' Delete a key
#'
#' Removes `key` and its value. Deleting a key that is not present is not an
#' error; the return value says which happened.
#'
#' @param txn An `mdbx_txn` object from [mdbx_txn_begin()], opened with
#'   `write = TRUE`.
#' @param key A raw vector, or a single string, which is stored as its UTF-8
#'   bytes.
#'
#' @param db An `mdbx_dbi` object from [mdbx_dbi_open()] naming a database to
#'   address instead of the unnamed main one, or `NULL` for the main database.
#' @return `TRUE` if a record existed and was removed, `FALSE` otherwise.
#'   Returned invisibly.
#' @seealso [mdbx_get()], [mdbx_put()]
#' @export
#' @examples
#' path <- tempfile(fileext = ".mdbx")
#' env <- mdbx_env_open(path)
#'
#' mdbx_with_write(env, function(txn) {
#'   mdbx_put(txn, "k", "v")
#'   mdbx_del(txn, "k")
#' })
#'
#' mdbx_env_close(env)
#' unlink(c(path, paste0(path, "-lck")))
mdbx_del <- function(txn, key, db = NULL) {
  key <- as_bytes(key, "key")

  invisible(mdbx_del_(txn, key, db_name(db, txn)))
}

# Coerce a key or value to the bytes MDBX will store.
#
# Raw passes through untouched. A single string is normalized with enc2utf8()
# before charToRaw(), which matters more than it looks: charToRaw() alone
# returns whatever bytes the string happens to carry, so the same text would
# become a different key depending on its Encoding() flag and the session
# locale -- "café" as latin1 is 63 61 66 e9, as UTF-8 it is 63 61 66 c3 a9.
# Normalizing first makes a character key mean the same bytes everywhere.
as_bytes <- function(x, arg) {
  if (is.raw(x)) {
    return(x)
  }

  if (is.character(x) && length(x) == 1L && !is.na(x)) {
    return(charToRaw(enc2utf8(x)))
  }

  stop(
    sprintf(
      "`%s` must be a raw vector or a single string; use serialize() for an arbitrary R object",
      arg
    ),
    call. = FALSE
  )
}
