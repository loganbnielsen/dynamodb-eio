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
    Dynamodb_client.t ->
    pk:I.pk -> sk:I.sk -> (Dynamodb_client.item option, Dynamodb_error.t) result
  (** Implemented as [Query] with an equality condition on [pk] and [sk] —
      DynamoDB has no [GetItem] for a secondary index. [Error
      (Malformed_response _)] if more than one item matches: secondary
      indexes don't enforce pk+sk uniqueness, so use {!query_all} instead of
      [get] where that's possible. *)

  val query_page :
    Dynamodb_client.t ->
    pk:I.pk -> ?exclusive_start_key:Dynamodb_client.item -> ?limit:int -> unit ->
    (Dynamodb_client.query_page, Dynamodb_error.t) result
  (** One DynamoDB page under [pk] on this index. *)

  val query_all :
    Dynamodb_client.t ->
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
      {!Index.get}/{!Index.query_page}/{!Index.query_all} returned before treating it as this
      entity's shape. *)
end

type 'a decoded_page = {
  items : 'a list;
  last_evaluated_key : Dynamodb_client.item option;
      (** Pass straight back into {!Index.query_page}'s [?exclusive_start_key] —
          this is still the raw item, not a domain value, since that's what
          the client's pagination cursor is. *)
}

module type OBJECT = sig
  type t

  val entity_name : string
  (** Stamped/checked via {!Entity} on this object's behalf — no separate
      [Entity] application needed at the call site. *)

  val encode : t -> Dynamodb_client.item
  (** Must not set the entity discriminator attribute itself — {!Object.encode}
      stamps it after calling this. *)

  val decode : Dynamodb_client.item -> (t, string) result
  (** Runs only after the discriminator has already been checked — this
      function doesn't need to re-check it. [Error msg] becomes
      [Dynamodb_error.Malformed_response msg]. *)
end

module Object (O : OBJECT) : sig
  val encode : O.t -> Dynamodb_client.item
  (** [O.encode] followed by stamping the entity discriminator. *)

  val decode : Dynamodb_client.item -> (O.t, Dynamodb_error.t) result
  (** Checks the entity discriminator first ([Error (Wrong_entity _)] on
      mismatch/missing), then runs [O.decode]. Callers cannot accidentally
      decode a different entity's item through this function. *)

  val decode_option : Dynamodb_client.item option -> (O.t option, Dynamodb_error.t) result
  (** For {!Index.get}'s [item option] result. [None] stays [Ok None]. *)

  val decode_list : Dynamodb_client.item list -> (O.t list, Dynamodb_error.t) result
  (** For {!Index.query_all}'s [item list] result. Fails on the first item
      that doesn't decode as this entity. *)

  val decode_page : Dynamodb_client.query_page -> (O.t decoded_page, Dynamodb_error.t) result
  (** For {!Index.query_page}'s result — decodes [items], carries
      [last_evaluated_key] through unchanged for the next page's
      [?exclusive_start_key]. *)
end
