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
- **Live-tested against a real table**: the version-stamp `update_item` CAS
  round trip and a new conditional-`put_item` create-iff-missing round trip
  (`Attribute_not_exists` succeeds once, fails `Conditional_check_failed` once
  the item exists) both proven against real DynamoDB. `scripts/setup.sh`'s
  inline policy was missing `dynamodb:UpdateItem` — fixed.
- Added explicit Query pagination: `Dynamodb_client.query_page` returns one
  page plus `LastEvaluatedKey`, while `query_all` drains every page. The typed
  index layer mirrors this as `Index.query_page`/`Index.query_all`.
- Caller-provided items/keys/cursors now reject duplicate attribute names with
  `Invalid_request` before building ambiguous JSON. `Entity.stamp` is
  idempotent and replaces any existing discriminator.
- `Dynamodb_client` now captures Eio capabilities in a client handle:
  `create ~net ~clock config`, then operations take that handle instead of
  repeating `~net ~clock config`.
- Public-API cleanup: request builders, JSON codecs, response interpreters,
  validators, expression compiler internals, and `Index.interpret_get_results`
  are private implementation details rather than installed interface symbols.
- `test_dynamodb_live.ml` gained coverage for the `update_op`/`condition`
  variants the CAS and create-iff-missing tests don't reach: `Remove`/`Add`/
  `Delete` (set mutation, not just `Set`/`Increment`) and `And`/`Or`/
  `Not_equals` (boolean composition, not just a bare `Equals`/
  `Attribute_not_exists`). Not yet run against a real table — gated the same
  way as the rest of `test_dynamodb_live.ml`.

## 0.1.0

- Initial standalone OPAM package: `Dynamodb_client` (`PutItem`/`GetItem`/
  `DeleteItem`/`Query`, single-page) and the `Dynamodb_table.Index`/`Entity`
  typed layer — one functor application per index (primary or secondary), so
  passing one index's key to another index's functions is a type error, not a
  runtime bug; a required, typed entity discriminator so multiple entity types
  sharing one physical table can't silently decode into the wrong OCaml shape.
- Live-tested against a real table: put/get/delete round trip + the
  missing-key path.
