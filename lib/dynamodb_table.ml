module type INDEX = sig
  type pk
  type sk

  val index_name : string option
  val format_pk : pk -> string
  val format_sk : sk -> string
  val pk_attribute : string
  val sk_attribute : string
end

module Index (I : INDEX) = struct
  (* DynamoDB only guarantees pk+sk uniqueness on the primary key, not on
     secondary indexes, so more than one item can match here. Fail loud
     rather than silently returning the first match — use query_all instead. *)
  let interpret_get_results = function
    | [] -> Ok None
    | [ item ] -> Ok (Some item)
    | _ :: _ :: _ as items ->
      Error
        (Dynamodb_error.Malformed_response
           (Printf.sprintf
              "Index.get expects at most one item for a fully-specified pk+sk, got %d — %s"
              (List.length items)
              (match I.index_name with
               | None -> "this is the primary index, which should be impossible; investigate the table schema"
               | Some name ->
                 Printf.sprintf
                   "%s is a secondary index, which DynamoDB does not enforce key uniqueness on; use query_all instead \
                    of get if more than one item can share this key"
                   name)))

  let get client ~pk ~sk =
    match
      Dynamodb_client.query_all client ?index_name:I.index_name
        ~key_condition:(Dynamodb_client.Pk_and_sk_equals {
          pk_attribute = I.pk_attribute; pk = Dynamodb_value.S (I.format_pk pk);
          sk_attribute = I.sk_attribute; sk = Dynamodb_value.S (I.format_sk sk);
        })
        ()
    with
    | Error _ as e -> e
    | Ok items -> interpret_get_results items

  let key_condition pk =
    Dynamodb_client.Pk_equals { pk_attribute = I.pk_attribute; pk = Dynamodb_value.S (I.format_pk pk) }

  let query_page client ~pk ?exclusive_start_key ?limit () =
    Dynamodb_client.query_page client ?index_name:I.index_name
      ?exclusive_start_key ?limit
      ~key_condition:(key_condition pk)
      ()

  let query_all client ~pk () =
    Dynamodb_client.query_all client ?index_name:I.index_name
      ~key_condition:(key_condition pk)
      ()
end

module type ENTITY = sig
  val name : string
end

module Entity (E : ENTITY) = struct
  let discriminator_attribute = "__dynamodb_eio_entity__"

  let stamp item = (discriminator_attribute, Dynamodb_value.S E.name) :: List.remove_assoc discriminator_attribute item

  let check item =
    match List.assoc_opt discriminator_attribute item with
    | Some (Dynamodb_value.S got) when got = E.name -> Ok item
    | Some (Dynamodb_value.S got) ->
      Error (Dynamodb_error.Wrong_entity { expected = E.name; got = Dynamodb_error.Wrong_value got })
    | Some other ->
      Error (Dynamodb_error.Wrong_entity { expected = E.name; got = Dynamodb_error.Wrong_type other })
    | None ->
      Error (Dynamodb_error.Wrong_entity { expected = E.name; got = Dynamodb_error.Missing })
end

type 'a decoded_page = {
  items : 'a list;
  last_evaluated_key : Dynamodb_client.item option;
}

module type OBJECT = sig
  type t

  val entity_name : string
  val encode : t -> Dynamodb_client.item
  val decode : Dynamodb_client.item -> (t, string) result
end

module Object (O : OBJECT) = struct
  module E = Entity (struct
    let name = O.entity_name
  end)

  let encode obj = E.stamp (O.encode obj)

  let decode item =
    match E.check item with
    | Error _ as e -> e
    | Ok item -> (
      match O.decode item with
      | Ok obj -> Ok obj
      | Error msg -> Error (Dynamodb_error.Malformed_response msg))

  let decode_option = function
    | None -> Ok None
    | Some item -> Result.map Option.some (decode item)

  let rec decode_list = function
    | [] -> Ok []
    | item :: rest -> (
      match decode item with
      | Error _ as e -> e
      | Ok obj -> Result.map (fun objs -> obj :: objs) (decode_list rest))

  let decode_page (page : Dynamodb_client.query_page) =
    match decode_list page.items with
    | Error _ as e -> e
    | Ok items -> Ok { items; last_evaluated_key = page.last_evaluated_key }
end
