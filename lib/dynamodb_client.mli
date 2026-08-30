(** Raw DynamoDB operations on top of [aws-eio]. See the project README's "Wire
    protocol" and "Out of Scope" sections for wire protocol details and what
    v1 deliberately leaves out (batch operations and transactions). *)

type config = {
  table : string;
  region : string;
  credentials : Aws_credentials.t;
}

type item = (string * Dynamodb_value.t) list

type condition =
  | Attribute_exists of string
  | Attribute_not_exists of string
  | Equals of string * Dynamodb_value.t
  | Not_equals of string * Dynamodb_value.t
  | And of condition * condition
  | Or of condition * condition
(** Compiles to a [ConditionExpression] — the small compare-and-swap surface
    DynamoDB's optimistic-locking idioms actually need: "create iff missing"
    ([Attribute_not_exists] on the primary key), "update iff unchanged" ([Equals]
    on a version-stamp attribute), and their boolean combinations. Deliberately
    not a full expression DSL — no [between]/[begins_with]/size comparisons;
    add those if a caller actually needs them. A failed condition comes back as
    [Error Conditional_check_failed], distinguishable from every other failure
    so a caller can retry-or-abort specifically on a lost race. *)

type update_op =
  | Set of string * Dynamodb_value.t
  | Increment of string * string
      (** [string], not [int]: {!Dynamodb_value.N} is already decimal-string-encoded
          (DynamoDB numbers are strings on the wire to avoid precision loss), and
          [int] would be narrower than what the wire format actually allows. Compiles
          to [SET attr = attr + :v]. *)
  | Remove of string
  | Add of string * Dynamodb_value.t  (** [ADD attr :v] — numeric increment or set union. *)
  | Delete of string * Dynamodb_value.t  (** [DELETE attr :v] — set-element removal. *)
(** Compiles to an [UpdateExpression]. Every attribute name and value is
    aliased ([#n0], [:v0], ...) unconditionally — DynamoDB reserves ~600 words
    that can't appear literally in an expression, and always aliasing avoids
    needing to know that list, matching [query_page]'s existing
    [expression_attribute_names] rationale. When {!update_item} is also given
    a [condition], both compile through one shared alias allocator, so a
    [ConditionExpression] and an [UpdateExpression] in the same request can
    never collide on the same [#n]/[:v] token. *)

type key_condition =
  | Pk_equals of { pk_attribute : string; pk : Dynamodb_value.t }
  | Pk_and_sk_equals of {
      pk_attribute : string; pk : Dynamodb_value.t;
      sk_attribute : string; sk : Dynamodb_value.t;
    }
(** Compiles to a [KeyConditionExpression], through the same alias allocator
    as {!condition}/{!update_op} — the two shapes {!val-query_page}/{!query_all}
    actually need: partition-key-only, and partition+sort-key equality. Like
    {!condition}, deliberately not the full range of sort-key comparisons
    DynamoDB's Query API supports ([<]/[<=]/[>]/[>=]/[between]/
    [begins_with]) — add those if a caller actually needs them. Before this
    type existed, callers built [KeyConditionExpression] as a raw string
    ["#pk = :pk"]) alongside separately-supplied attribute-name/value
    aliases, with nothing but a hand-followed naming convention tying the
    two together; this makes that class of mismatch impossible to
    construct. *)

type query_page = {
  items : item list;
  last_evaluated_key : item option;
}

type t

val create : net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> fs:Eio.Fs.dir_ty Eio.Path.t -> config -> t
(** [fs] is used only when [config.credentials] resolves via [Web_identity]
    (a Kubernetes-projected service-account token file) — pass
    [Eio.Stdenv.fs env]. *)

val put_item :
  t -> ?condition:condition -> item:item -> unit ->
  (unit, Dynamodb_error.t) result
(** [?condition] compiles to a [ConditionExpression] on the same request — e.g.
    [Attribute_not_exists pk_attribute] for "create iff this key doesn't
    already exist". [Error Conditional_check_failed] if it doesn't hold. *)

val get_item : t -> key:item -> (item option, Dynamodb_error.t) result
(** [None] when the key doesn't exist — GetItem returns HTTP 200 with no
    ["Item"] field in that case, not a 404 (unlike S3's GetObject
    404-on-missing-key; DynamoDB's protocol just works differently). *)

val delete_item :
  t -> ?condition:condition -> key:item -> unit ->
  (unit, Dynamodb_error.t) result
(** Without [?condition]: succeeds whether or not the key existed — DynamoDB's
    DeleteItem does not report "not found" as an error. With [?condition]:
    [Error Conditional_check_failed] if it doesn't hold (this includes the key
    not existing, if the condition references an attribute of the item itself —
    a condition can't hold against an item that isn't there). *)

val update_item :
  t -> ?condition:condition -> key:item -> updates:update_op list ->
  unit -> (unit, Dynamodb_error.t) result
(** [Error Empty_updates] if [updates] is [[]], checked before any request is
    built — DynamoDB requires a non-empty [UpdateExpression]. Update clauses
    are grouped by keyword ([SET]/[REMOVE]/[ADD]/[DELETE]) into one expression,
    matching DynamoDB's grammar (each keyword may appear at most once). *)

val query_all :
  t ->
  ?index_name:string ->
  key_condition:key_condition ->
  unit ->
  (item list, Dynamodb_error.t) result
(** Drains pages until DynamoDB returns no [LastEvaluatedKey]. *)

val query_page :
  t ->
  ?index_name:string ->
  ?exclusive_start_key:item ->
  ?limit:int ->
  key_condition:key_condition ->
  unit ->
  (query_page, Dynamodb_error.t) result
(** Returns one DynamoDB Query page. [?limit] maps directly to DynamoDB's
    [Limit]; use [last_evaluated_key] as the next [?exclusive_start_key]. *)
