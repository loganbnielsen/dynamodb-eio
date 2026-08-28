# dynamodb-eio

An Eio-native DynamoDB client built on [aws-eio](https://github.com/loganbnielsen/aws-eio)
— "the ElectroDB-replacement layer." A typed indexing layer is the actual reason
this exists, not just a raw API binding.

Originally developed inside the [Sun](https://github.com/loganbnielsen/sun)
platform, and extracted here to be usable standalone.

**Live-tested successfully** (`test/test_dynamodb_live.ml`) against a real
table: put/get/delete round trip, the missing-key path, a version-stamp
conditional-`update_item` CAS round trip (succeeds once, then fails
`Conditional_check_failed` on the same now-stale condition), and a
conditional `put_item` create-iff-missing round trip (succeeds once, then
fails `Conditional_check_failed` once the item exists). The first of these
required a fix in `aws-eio` itself
([`aws-eio#5`](https://github.com/loganbnielsen/aws-eio/pull/5)), though
DynamoDB itself doesn't require the header that fix adds (S3 does; that's how
it was originally caught). `scripts/setup.sh`/`teardown.sh` provision a real
table for this in your own AWS account — see their headers for usage.

## Build

```bash
eval $(opam env)
dune build
```

## Test

```bash
dune runtest
```

No external infrastructure required for the default test run. A live test
gated by `DYNAMODB_EIO_LIVE=1` (real table + credentials required) is in
`test/test_dynamodb_live.ml` and is skipped otherwise. `scripts/setup.sh`
provisions a dedicated table for it in your own AWS account
(`scripts/teardown.sh` removes it) — see their headers for usage.
`test/negative_index_mismatch.ml.txt` documents (and was used to hand-verify)
a compile-time guarantee — see its own header for why it isn't wired into an
automated dune rule.

## Overview

DynamoDB's wire protocol is JSON over a single fixed regional endpoint
(`dynamodb.<region>.amazonaws.com`) — simpler in that respect than S3's
XML/virtual-hosting concerns. The hard part is the *data model*: composite
partition/sort keys, secondary indexes, and multiple entity types sharing one
physical table. ElectroDB (the TypeScript library this layer replaces) solves
this with runtime-templated key strings (`` `USER#${id}` ``) — a missing or
reordered parameter is a runtime bug, sometimes silent (wrong partition, not
an error), and querying an index with the wrong key shape is a runtime
failure, not a compile error.

`dynamodb-eio` fixes this with one module per index, each carrying its own
nominally distinct `pk`/`sk` types, generating its own typed `get`/`query` via
a functor — the same shape as a table-per-schema functor, applied once per
index instead of once per table. Passing one index's key to another index's
functions is a **type error**, not a runtime bug.

## Wire protocol

Every request: `POST /` to `dynamodb.<region>.amazonaws.com`, `Content-Type:
application/x-amz-json-1.0`, `X-Amz-Target: DynamoDB_20120810.<Action>` (e.g.
`DynamoDB_20120810.PutItem`), JSON body. SigV4 `service = "dynamodb"`,
`normalize_path = true`. Throttling
(`ProvisionedThroughputExceededException`) and 5xx retries are already handled
by `aws-eio`'s `signed_request`.

Errors: a non-2xx response is a JSON body `{"__type": "...#SomeException",
"message": "..."}`. `Dynamodb_error.of_response` classifies
`ConditionalCheckFailedException` and `ResourceNotFoundException` as their own
cases; anything else parseable becomes `Service_error`; anything unparseable
becomes `Unparseable_error_response`.

## `Dynamodb_value.t` — DynamoDB's attribute-value encoding

```ocaml
type t =
  | S of string
  | N of string  (** DynamoDB numbers are wire-encoded as decimal strings, not JSON
                     numbers, specifically to avoid precision loss on large integers —
                     encoding a real OCaml int/float is the caller's job. *)
  | B of string  (** Raw bytes; base64-encoded only at the JSON boundary. *)
  | Bool of bool
  | Null
  | Ss of string list
  | Ns of string list
  | Bs of string list
  | L of t list
  | M of (string * t) list

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
```

## `Dynamodb_client` — raw operations

```ocaml
type config = { table : string; region : string; credentials : Aws_credentials.t }
type item = (string * Dynamodb_value.t) list

(* The small compare-and-swap surface DynamoDB's optimistic-locking idioms actually
   need — not a full expression DSL. Add between/begins_with/comparisons if a caller
   ever needs them. *)
type condition =
  | Attribute_exists of string
  | Attribute_not_exists of string       (* "create iff missing" *)
  | Equals of string * Dynamodb_value.t  (* the version-stamp CAS idiom *)
  | Not_equals of string * Dynamodb_value.t
  | And of condition * condition
  | Or of condition * condition

type update_op =
  | Set of string * Dynamodb_value.t
  | Increment of string * string  (* string, not int: N is already decimal-string-encoded *)
  | Remove of string
  | Add of string * Dynamodb_value.t
  | Delete of string * Dynamodb_value.t

val put_item :
  net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> config -> ?condition:condition -> item:item -> unit ->
  (unit, Dynamodb_error.t) result
val get_item : net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> config -> key:item -> (item option, Dynamodb_error.t) result
val delete_item :
  net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> config -> ?condition:condition -> key:item -> unit ->
  (unit, Dynamodb_error.t) result
val update_item :
  net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> config -> ?condition:condition -> key:item ->
  updates:update_op list -> unit -> (unit, Dynamodb_error.t) result
(** [Error Empty_updates] if [updates = []], checked before any request is built.
    A [condition] that doesn't hold comes back as [Error Conditional_check_failed] —
    distinguishable from every other failure, so a caller can retry-or-abort
    specifically on a lost race. A single [update_item] call's [condition] and
    [updates] compile through one shared [#n]/[:v] alias allocator, so they can
    never collide on the same placeholder even when they reference the same
    attribute (e.g. a version-stamp CAS: `condition:(Equals ("version", N "5"))`
    alongside `updates:[ Increment ("version", "1") ]`). *)

val query :
  net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> config ->
  ?index_name:string ->
  ?expression_attribute_names:(string * string) list ->
  key_condition_expression:string ->
  expression_attribute_values:item ->
  unit ->
  (item list, Dynamodb_error.t) result
(** Single page only — v1 does not read [LastEvaluatedKey]. A query whose real result
    set exceeds DynamoDB's 1MB-per-page limit silently returns only the first page; see
    "Out of Scope". *)
```

## `Dynamodb_table` — the typed indexing layer

```ocaml
module type INDEX = sig
  type pk
  type sk

  val index_name : string option  (** [None] = the table's primary index. *)
  val format_pk : pk -> string
  val format_sk : sk -> string
  val pk_attribute : string  (** the index's partition-key attribute name *)
  val sk_attribute : string  (** the index's sort-key attribute name *)
end

module Index (I : INDEX) : sig
  val get :
    net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> Dynamodb_client.config ->
    pk:I.pk -> sk:I.sk -> (Dynamodb_client.item option, Dynamodb_error.t) result

  val query :
    net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> Dynamodb_client.config ->
    pk:I.pk -> unit -> (Dynamodb_client.item list, Dynamodb_error.t) result
  (** Queries every item under [pk] on this index — the [sk] is deliberately not
      a parameter here; a query that needs a sort-key condition beyond "starts
      with this partition" is real, deferred scope (see "Out of Scope"). *)
end

module type ENTITY = sig
  val name : string  (** stamped into the reserved discriminator attribute on
                          every put, and checked on every decode. *)
end

module Entity (E : ENTITY) : sig
  val discriminator_attribute : string  (** ["__dynamodb_eio_entity__"] *)

  val stamp : Dynamodb_client.item -> Dynamodb_client.item
  (** Adds the discriminator attribute — call before [Dynamodb_client.put_item]. *)

  val check : Dynamodb_client.item -> (Dynamodb_client.item, Dynamodb_error.t) result
  (** [Error (Wrong_entity got)] if the stamped name doesn't match [E.name] (or
      is missing) — call after [Dynamodb_client.get_item]/[query] before treating
      the item as this entity's shape. *)
end
```

The two functors compose independently — `Index` handles key-shape safety,
`Entity` handles cross-entity-type discrimination on a shared table. A caller
who wants both applies `Entity(E).stamp` before `Index(I).get`'s underlying
put, and `Entity(E).check` on what `Index(I).get`/`query` return.

**The one guarantee that has to be a compile-time check, not a runtime
assertion:** passing `User_by_email`'s `` `Email `` key to
`Index(User_primary)`'s functions must fail to *compile* —
`[ \`Org of string ]` and `[ \`Email of string ]` don't unify. This is the
entire point of the design; a runtime test would only prove the design
accidentally degraded to ElectroDB's own weaker guarantee.

## Example Usage

```ocaml
module User_primary = struct
  type pk = [ `Org of string ]
  type sk = [ `User of string ]
  let index_name = None
  let format_pk (`Org id) = "ORG#" ^ id
  let format_sk (`User id) = "USER#" ^ id
  let pk_attribute = "PK"
  let sk_attribute = "SK"
end

module Users = Dynamodb_table.Index (User_primary)
module User_entity = Dynamodb_table.Entity (struct let name = "user" end)

let config = { Dynamodb_client.table = "app"; region = "us-east-1"; credentials }

(* let _ = Users.get ~net ~clock config ~pk:(`Email "x") ~sk:(`User "y")
   -- does not compile: `Email is User_by_email's pk type, not User_primary's *)
```

## Out of Scope (v1)

- **Pagination** (`LastEvaluatedKey`) — needs a typed cursor to avoid
  ElectroDB's own pagination footgun (a cursor silently valid for the wrong
  index/query); real design work, not done here. `query` in v1 always returns
  exactly one page.
- **`Index.query`'s sort-key conditions** (`begins_with`, `between`,
  comparisons beyond "all items under this partition") — v1's `query` only
  takes a partition key.
- **Batch operations** (`BatchGetItem`/`BatchWriteItem`) — different
  request/response shape (multiple items per call), not a small extension of
  the single-item operations.
- **Transactions** (`TransactWriteItems`) — real, separate scope.
