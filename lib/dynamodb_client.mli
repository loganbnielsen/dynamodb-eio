(** Raw DynamoDB operations on top of [aws-eio]. See [dynamo-eio.md] for wire
    protocol details and what v1 deliberately leaves out (pagination, update
    expressions, conditional writes, batch/transactions). *)

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
    needing to know that list, matching {!query}'s existing
    [expression_attribute_names] rationale. When {!update_item} is also given
    a [condition], both compile through one shared alias allocator, so a
    [ConditionExpression] and an [UpdateExpression] in the same request can
    never collide on the same [#n]/[:v] token. *)

val put_item :
  net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> config -> ?condition:condition -> item:item -> unit ->
  (unit, Dynamodb_error.t) result
(** [?condition] compiles to a [ConditionExpression] on the same request — e.g.
    [Attribute_not_exists pk_attribute] for "create iff this key doesn't
    already exist". [Error Conditional_check_failed] if it doesn't hold. *)

val get_item : net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> config -> key:item -> (item option, Dynamodb_error.t) result
(** [None] when the key doesn't exist — GetItem returns HTTP 200 with no
    ["Item"] field in that case, not a 404 (unlike {!S3_client.get_object}'s
    404-on-missing-key; DynamoDB's protocol just works differently). *)

val delete_item :
  net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> config -> ?condition:condition -> key:item -> unit ->
  (unit, Dynamodb_error.t) result
(** Without [?condition]: succeeds whether or not the key existed — DynamoDB's
    DeleteItem does not report "not found" as an error. With [?condition]:
    [Error Conditional_check_failed] if it doesn't hold (this includes the key
    not existing, if the condition references an attribute of the item itself —
    a condition can't hold against an item that isn't there). *)

val update_item :
  net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> config -> ?condition:condition -> key:item -> updates:update_op list ->
  unit -> (unit, Dynamodb_error.t) result
(** [Error Empty_updates] if [updates] is [[]], checked before any request is
    built — DynamoDB requires a non-empty [UpdateExpression]. Update clauses
    are grouped by keyword ([SET]/[REMOVE]/[ADD]/[DELETE]) into one expression,
    matching DynamoDB's grammar (each keyword may appear at most once). *)

val query :
  net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> config ->
  ?index_name:string ->
  ?expression_attribute_names:(string * string) list
      (** ["#name" -> "real_attribute_name"] aliases for
          [key_condition_expression] — DynamoDB reserves ~600 words that
          can't appear literally in an expression; aliasing avoids the
          caller needing to know that list. *)
  -> key_condition_expression:string ->
  expression_attribute_values:item ->
  unit ->
  (item list, Dynamodb_error.t) result
(** Single page only — does not read [LastEvaluatedKey]. A query whose real
    result set exceeds DynamoDB's 1MB-per-page limit silently returns only
    the first page; see [dynamo-eio.md]'s "Out of Scope". *)

(** {2 Exposed for testing} *)

val build_request_body : (string * Yojson.Safe.t) list -> string
(** The exact JSON body an operation signs and sends, given its
    action-specific fields (["TableName"], ["Item"]/["Key"]/etc.). *)

val item_to_json : item -> Yojson.Safe.t
val item_of_json : Yojson.Safe.t -> (item, string) result

val validate_config : config -> (unit, Dynamodb_error.t) result
(** The CR/LF fail-closed check every operation runs before building a
    request — [config.region] becomes an unencoded Host header/connection
    target with no percent-encoding pass. *)

val reclassify_transport_result :
  (int * (string * string) list * string, Aws_error.t) result ->
  (int * (string * string) list * string, Dynamodb_error.t) result
(** [Aws_http.signed_request] already converts every non-2xx status into
    [Error (Http_error (status, body))] — this re-threads that back into the
    [Ok] shape [interpret_*] expects, so their non-2xx classification
    branches are actually reachable. *)

val interpret_put : int * (string * string) list * string -> (unit, Dynamodb_error.t) result
val interpret_get : int * (string * string) list * string -> (item option, Dynamodb_error.t) result
val interpret_delete : int * (string * string) list * string -> (unit, Dynamodb_error.t) result
val interpret_query : int * (string * string) list * string -> (item list, Dynamodb_error.t) result
val interpret_update : int * (string * string) list * string -> (unit, Dynamodb_error.t) result

type alias_state
(** The shared [#n]/[:v] allocator threaded through {!compile_condition} and
    {!compile_updates} within a single call, so the two compilers can never
    hand out a colliding alias. *)

val new_alias_state : unit -> alias_state
val compile_condition : alias_state -> condition -> string
val compile_updates : alias_state -> update_op list -> string
val alias_fields : alias_state -> (string * Yojson.Safe.t) list
(** [ExpressionAttributeNames]/[ExpressionAttributeValues] request-body
    fields accumulated in [state] so far — [[]] for either that's still empty,
    matching {!query}'s existing "omit when there's nothing to alias" shape. *)
