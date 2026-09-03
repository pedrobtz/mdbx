# Package index

## Environments

Opening, closing and inspecting the file that holds the data.

- [`mdbx_env_open()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_env_open.md)
  : Open an MDBX environment
- [`mdbx_env_close()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_env_close.md)
  : Close an MDBX environment
- [`mdbx_env_is_open()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_env_is_open.md)
  : Is an MDBX environment still open?
- [`mdbx_env_stat()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_env_stat.md)
  : Database statistics
- [`mdbx_env_info()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_env_info.md)
  : Environment information
- [`mdbx_limits()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_limits.md)
  : Size limits imposed by 'libmdbx'
- [`mdbx_env_reader_check()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_env_reader_check.md)
  : Reclaim reader slots from processes that died

## Transactions

Every read and write happens inside one. The `with_*` helpers cover most
uses; the rest are for driving a transaction by hand.

- [`mdbx_with_write()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_with_write.md)
  [`mdbx_with_read()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_with_write.md)
  : Run code inside a transaction
- [`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_txn_begin.md)
  : Begin a transaction
- [`mdbx_txn_commit()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_txn_commit.md)
  : Commit a transaction
- [`mdbx_txn_abort()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_txn_abort.md)
  : Abort a transaction
- [`mdbx_txn_state()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_txn_state.md)
  : State of a transaction

## Reading and writing

- [`mdbx_get()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_get.md)
  : Read a value
- [`mdbx_put()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_put.md)
  : Write a value
- [`mdbx_del()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_del.md)
  : Delete a key

## Named databases

An environment can hold several independent key spaces; the unnamed main
database is the default everywhere.

- [`mdbx_dbi_open()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_dbi_open.md)
  : Open a named database

- [`mdbx_dbi_drop()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_dbi_drop.md)
  : Empty or delete a named database

- [`mdbx_dbi_list()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_dbi_list.md)
  : List the named databases in an environment

- [`mdbx_dbi_sequence()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_dbi_sequence.md)
  : A database's sequence counter

- [`mdbx_keys()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_keys.md)
  : List the keys in a database

- [`mdbx_items()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_items.md)
  : List the keys and values in a database

- [`mdbx_scan_max`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_scan_max.md)
  :

  Largest scan
  [`mdbx_keys()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_keys.md)
  and
  [`mdbx_items()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_items.md)
  will do unasked

## Durability and flags

Every commit is durable by default; these trade that for speed.

- [`mdbx_flags()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_flags.md)
  : Flags accepted by 'libmdbx'
- [`mdbx_env_get_flags()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_env_get_flags.md)
  : Flags an environment is using
- [`mdbx_env_set_flags()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_env_set_flags.md)
  : Change an environment's flags
- [`mdbx_env_sync()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_env_sync.md)
  : Flush an environment to disk

## About the package

- [`mdbx`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx-package.md)
  [`mdbx-package`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx-package.md)
  : mdbx: Bindings to the 'libmdbx' Embedded Key-Value Store
- [`mdbx-concurrency`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx-concurrency.md)
  : Concurrency in mdbx
- [`mdbx_version()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_version.md)
  : Version of the bundled libmdbx
