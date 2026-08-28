# Changes

## Unreleased

- Added `update_item` (`UpdateExpression`, built from a typed `update_op` list:
  `Set`/`Increment`/`Remove`/`Add`/`Delete` — never a hand-written expression
  string) and conditional writes (a typed `condition` type: `Attribute_exists`/
  `Attribute_not_exists`/`Equals`/`Not_equals`/`And`/`Or`, compiling to
  `ConditionExpression`) on `put_item`, `delete_item`, and the new `update_item`.
  This is the compare-and-swap surface DynamoDB's optimistic-locking idioms
  need — "create iff missing", "update iff unchanged" (version-stamp CAS) — that
  v1 deliberately deferred. A condition that doesn't hold comes back as
  `Error Conditional_check_failed`, distinguishable from every other failure.
  A single call's condition and update clauses compile through one shared
  `#n`/`:v` alias allocator, so they can never collide on the same placeholder
  even when they reference the same attribute.
- `put_item`/`delete_item` now take a trailing `()` (required once `?condition`
  became their last optional argument — OCaml can't erase an optional argument
  with no positional argument after it).

## 0.1.0

- Initial standalone OPAM package: `Dynamodb_client` (`PutItem`/`GetItem`/
  `DeleteItem`/`Query`, single-page) and the `Dynamodb_table.Index`/`Entity`
  typed layer — one functor application per index (primary or secondary), so
  passing one index's key to another index's functions is a type error, not a
  runtime bug; a required, typed entity discriminator so multiple entity types
  sharing one physical table can't silently decode into the wrong OCaml shape.
- Live-tested against a real table: put/get/delete round trip + the
  missing-key path.
