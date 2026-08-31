(** Error type for {!Dynamodb_client}/{!Dynamodb_table}, extending [Aws.Error.t]
    the same way [kafka-eio-service]'s [Kafka_error.t] extends the raw
    librdkafka codes. *)

type discriminator_shape =
  | Missing  (** The discriminator attribute wasn't present on the item at all. *)
  | Wrong_type of Dynamodb_value.t
      (** The attribute was present but wasn't a string — a different failure
          than [Missing]: this is data corruption or a schema mismatch, not a
          genuinely absent field. *)
  | Wrong_value of string
      (** The attribute was a string, but not the expected entity name —
          carries the entity name that was actually stamped. *)

type t =
  | Aws of Aws.Error.t
      (** Transport, signature, or credential-resolution failure from
          [aws-eio] itself. *)
  | Resource_not_found  (** [ResourceNotFoundException] — table/index doesn't exist. *)
  | Conditional_check_failed  (** [ConditionalCheckFailedException]. *)
  | Service_error of { exn_type : string; message : string }
      (** Other DynamoDB exception with a parseable [__type]/[message] body. *)
  | Unparseable_error_response of { status : int; body : string }
      (** Non-2xx whose body didn't parse as DynamoDB's JSON error shape. *)
  | Malformed_response of string
      (** A 2xx response whose JSON didn't have the shape the calling
          operation expected (e.g. [GetItem] without an [Item] or
          [ConsumedCapacity]-only response) — distinct from a transport or
          service-reported error. *)
  | Wrong_entity of { expected : string; got : discriminator_shape }
      (** {!Dynamodb_table.Entity}'s discriminator check failed: the item's
          stamped entity name didn't match [expected]. *)
  | Invalid_config of string
      (** [config.region] failed a fail-closed CR/LF check before being used
          to build the Host header/connection target. *)
  | Invalid_request of string
      (** A caller-provided item/key/cursor/limit was rejected before any
          request was sent. *)
  | Empty_updates
      (** {!Dynamodb_client.update_item} was called with an empty [updates]
          list — DynamoDB requires a non-empty [UpdateExpression]; rejected
          before a request is ever built. *)

val of_response : status:int -> body:string -> t
(** Classify a non-2xx DynamoDB response: [ResourceNotFoundException]/
    [ConditionalCheckFailedException] in [__type] become their own cases;
    any other parseable [{"__type": ..., "message": ...}] body becomes
    [Service_error]; anything else becomes [Unparseable_error_response]. *)

val to_string : t -> string
