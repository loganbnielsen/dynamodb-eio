(** The typed indexing layer — see the project README's "Overview" section
    for the ElectroDB-replacement design rationale. One functor application per
    index (primary or secondary); passing one index's key to another index's
    functions is a type error, not a runtime bug. *)

module type INDEX = sig
  type pk
  type sk

  val index_name : string option
      (** [None] = the table's primary index; [Some gsi_name] = a global/local
          secondary index. *)

  val format_pk : pk -> string
  val format_sk : sk -> string

  val pk_attribute : string
  (** the index's partition-key attribute name *)

  val sk_attribute : string
  (** the index's sort-key attribute name *)
end

module Index (I : INDEX) : sig
  val get :
    net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> Dynamodb_client.config ->
    pk:I.pk -> sk:I.sk -> (Dynamodb_client.item option, Dynamodb_error.t) result
  (** Implemented as [Query] with an equality condition on [pk] and [sk] —
      DynamoDB has no [GetItem] for a secondary index. [Error
      (Malformed_response _)] if more than one item matches: secondary
      indexes don't enforce pk+sk uniqueness, so use {!query} instead of
      [get] where that's possible. *)

  val interpret_get_results : Dynamodb_client.item list -> (Dynamodb_client.item option, Dynamodb_error.t) result
  (** [get]'s pure result-interpretation step, exposed for testing — no
      network call needed to exercise the multi-item (non-unique-index)
      case. *)

  val query :
    net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> Dynamodb_client.config ->
    pk:I.pk -> unit -> (Dynamodb_client.item list, Dynamodb_error.t) result
  (** Every item under [pk] on this index. [sk] is deliberately not a
      parameter — a query needing a sort-key condition beyond "every item in
      this partition" is real, deferred scope; see the project README's
      "Out of Scope" section. *)
end

module type ENTITY = sig
  val name : string
end

module Entity (E : ENTITY) : sig
  val discriminator_attribute : string

  val stamp : Dynamodb_client.item -> Dynamodb_client.item
  (** Adds the discriminator attribute — call before {!Dynamodb_client.put_item}. *)

  val check : Dynamodb_client.item -> (Dynamodb_client.item, Dynamodb_error.t) result
  (** [Error (Wrong_entity _)] if the stamped name doesn't match [E.name] (or
      is missing entirely) — call on whatever {!Dynamodb_client.get_item}/
      {!Index.get}/{!Index.query} returned before treating it as this
      entity's shape. *)
end
