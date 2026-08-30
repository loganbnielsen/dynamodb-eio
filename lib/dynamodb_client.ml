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

type update_op =
  | Set of string * Dynamodb_value.t
  | Increment of string * string
  | Remove of string
  | Add of string * Dynamodb_value.t
  | Delete of string * Dynamodb_value.t

type query_page = {
  items : item list;
  last_evaluated_key : item option;
}

type t = {
  net : [`Generic] Eio.Net.ty Eio.Std.r;
  clock : float Eio.Time.clock_ty Eio.Std.r;
  fs : Eio.Fs.dir_ty Eio.Path.t;
  config : config;
}

let create ~net ~clock ~fs config =
  { net = (net :> [`Generic] Eio.Net.ty Eio.Std.r);
    clock = (clock :> float Eio.Time.clock_ty Eio.Std.r);
    fs;
    config;
  }

let ( let* ) = Result.bind

let item_to_json (item : item) : Yojson.Safe.t =
  `Assoc (List.map (fun (k, v) -> (k, Dynamodb_value.to_json v)) item)

let validate_item item =
  let seen = Hashtbl.create (List.length item) in
  match
    List.find_opt
      (fun (name, _) ->
        let duplicate = Hashtbl.mem seen name in
        Hashtbl.replace seen name ();
        duplicate)
      item
  with
  | None -> Ok ()
  | Some (name, _) -> Error (Dynamodb_error.Invalid_request ("duplicate attribute: " ^ name))

let item_of_json = function
  | `Assoc fields ->
    List.fold_left
      (fun acc (k, v) ->
        let* acc = acc in
        let* v = Dynamodb_value.of_json v in
        Ok ((k, v) :: acc))
      (Ok []) fields
    |> Result.map List.rev
  | json -> Error ("expected a JSON object for a DynamoDB item, got: " ^ Yojson.Safe.to_string json)

let build_request_body fields = Yojson.Safe.to_string (`Assoc fields)

(* Shared [#n]/[:v] allocator: threaded through both compile_condition and
   compile_updates for a single update_item/put_item/delete_item call so a
   ConditionExpression and an UpdateExpression sharing one request can never
   hand out a colliding alias, even when they reference the same attribute. *)
type alias_state = {
  mutable next_n : int;
  mutable next_v : int;
  mutable names : (string * string) list;  (* alias -> real attribute name *)
  mutable values : (string * Dynamodb_value.t) list;  (* alias -> value *)
}

let new_alias_state () = { next_n = 0; next_v = 0; names = []; values = [] }

let alias_name state attr =
  let alias = Printf.sprintf "#n%d" state.next_n in
  state.next_n <- state.next_n + 1;
  state.names <- (alias, attr) :: state.names;
  alias

let alias_value state v =
  let alias = Printf.sprintf ":v%d" state.next_v in
  state.next_v <- state.next_v + 1;
  state.values <- (alias, v) :: state.values;
  alias

let alias_fields state =
  (if state.names = [] then []
   else [ ("ExpressionAttributeNames", `Assoc (List.map (fun (alias, attr) -> (alias, `String attr)) state.names)) ])
  @ (if state.values = [] then [] else [ ("ExpressionAttributeValues", item_to_json (List.rev state.values)) ])

(* Every branch below binds its sub-results with `let` before formatting them
   into one string, rather than calling alias_name/alias_value (or a
   recursive compile_condition) directly as Printf.sprintf arguments — OCaml
   does not guarantee left-to-right argument evaluation order, and these
   calls mutate `state`'s counters, so evaluating them as bare sprintf
   arguments would make the #n/:v numbering (still correct, just
   unpredictable) depend on unspecified evaluation order. *)
let rec compile_condition state = function
  | Attribute_exists attr ->
    let n = alias_name state attr in
    Printf.sprintf "attribute_exists(%s)" n
  | Attribute_not_exists attr ->
    let n = alias_name state attr in
    Printf.sprintf "attribute_not_exists(%s)" n
  | Equals (attr, v) ->
    let n = alias_name state attr in
    let value = alias_value state v in
    Printf.sprintf "%s = %s" n value
  | Not_equals (attr, v) ->
    let n = alias_name state attr in
    let value = alias_value state v in
    Printf.sprintf "%s <> %s" n value
  | And (a, b) ->
    let ea = compile_condition state a in
    let eb = compile_condition state b in
    Printf.sprintf "(%s) AND (%s)" ea eb
  | Or (a, b) ->
    let ea = compile_condition state a in
    let eb = compile_condition state b in
    Printf.sprintf "(%s) OR (%s)" ea eb

(* Grouped by keyword, per DynamoDB's UpdateExpression grammar: each of
   SET/REMOVE/ADD/DELETE may appear at most once in the whole expression, so
   every op of a given kind folds into that one clause rather than repeating
   the keyword per op. *)
let compile_updates state ops =
  let sets = ref [] and removes = ref [] and adds = ref [] and deletes = ref [] in
  List.iter
    (function
      | Set (attr, v) ->
        let n = alias_name state attr in
        let value = alias_value state v in
        sets := Printf.sprintf "%s = %s" n value :: !sets
      | Increment (attr, delta) ->
        let n = alias_name state attr in
        let v = alias_value state (Dynamodb_value.N delta) in
        sets := Printf.sprintf "%s = %s + %s" n n v :: !sets
      | Remove attr -> removes := alias_name state attr :: !removes
      | Add (attr, v) ->
        let n = alias_name state attr in
        let value = alias_value state v in
        adds := Printf.sprintf "%s %s" n value :: !adds
      | Delete (attr, v) ->
        let n = alias_name state attr in
        let value = alias_value state v in
        deletes := Printf.sprintf "%s %s" n value :: !deletes)
    ops;
  [ ("SET", !sets); ("REMOVE", !removes); ("ADD", !adds); ("DELETE", !deletes) ]
  |> List.filter_map (fun (keyword, items) ->
       match List.rev items with [] -> None | items -> Some (keyword ^ " " ^ String.concat ", " items))
  |> String.concat " "

let resolve_credentials ~net ~clock ~fs config =
  match Aws_credentials.resolve ~net ~clock ~fs config.credentials with
  | Error e -> Error (Dynamodb_error.Aws e)
  | Ok creds -> Ok creds

let has_crlf s = String.exists (fun c -> c = '\r' || c = '\n') s

(* config.region is spliced unvalidated into the Host header — CRLF
   injection risk if unchecked. table isn't checked: it only appears in the
   JSON body, safely encoded by Yojson. *)
let validate_config config =
  if has_crlf config.region then Error (Dynamodb_error.Invalid_config "region contains a CR or LF character")
  else Ok ()

(* aws-eio's signed_request already turns non-2xx into Error before
   returning; this re-threads it into Ok so interpret_*'s non-2xx branches
   are actually reachable. Pure and separate so it's testable without a
   real network/TLS path. *)
let reclassify_transport_result :
    (int * (string * string) list * string, Aws_error.t) result ->
    (int * (string * string) list * string, Dynamodb_error.t) result = function
  | Error (Aws_error.Http_error (status, body)) -> Ok (status, [], body)
  | Error e -> Error (Dynamodb_error.Aws e)
  | Ok (status, headers, body) -> Ok (status, headers, body)

(* Credentials are resolved fresh on every call — no caching; see
   dynamo-eio.md's "Out of Scope". *)
let call t ~action ~body () =
  let* () = validate_config t.config in
  let* creds = resolve_credentials ~net:t.net ~clock:t.clock ~fs:t.fs t.config in
  let host = Printf.sprintf "dynamodb.%s.amazonaws.com" t.config.region in
  let extra_headers =
    [ ("Content-Type", "application/x-amz-json-1.0");
      ("X-Amz-Target", "DynamoDB_20120810." ^ action);
    ]
  in
  reclassify_transport_result
    (Aws_http.signed_request ~net:t.net ~clock:t.clock
       ~access_key_id:creds.access_key_id
       ~secret_access_key:creds.secret_access_key
       ?session_token:creds.session_token
       ~region:t.config.region ~service:"dynamodb" ~normalize_path:true
       ~meth:`POST ~host ~path:"/" ~extra_headers ~body ())

(* Pure and separate from call so it's unit-testable with synthetic
   (status, headers, body) triples. *)
let interpret_put (status, _headers, body) =
  if status >= 200 && status < 300 then Ok () else Error (Dynamodb_error.of_response ~status ~body)

let interpret_get (status, _headers, body) =
  if status < 200 || status >= 300 then Error (Dynamodb_error.of_response ~status ~body)
  else
    match Yojson.Safe.from_string body with
    | exception Yojson.Json_error _ ->
      Error (Dynamodb_error.Malformed_response ("GetItem response is not valid JSON: " ^ body))
    | `Assoc fields -> (
      match List.assoc_opt "Item" fields with
      | None -> Ok None
      | Some item_json -> (
        match item_of_json item_json with
        | Ok item -> Ok (Some item)
        | Error msg -> Error (Dynamodb_error.Malformed_response msg)))
    | json -> Error (Dynamodb_error.Malformed_response ("expected a JSON object, got: " ^ Yojson.Safe.to_string json))

let interpret_delete (status, _headers, body) =
  if status >= 200 && status < 300 then Ok () else Error (Dynamodb_error.of_response ~status ~body)

let interpret_update (status, _headers, body) =
  if status >= 200 && status < 300 then Ok () else Error (Dynamodb_error.of_response ~status ~body)

let interpret_query_page (status, _headers, body) =
  if status < 200 || status >= 300 then Error (Dynamodb_error.of_response ~status ~body)
  else
    match Yojson.Safe.from_string body with
    | exception Yojson.Json_error _ ->
      Error (Dynamodb_error.Malformed_response ("Query response is not valid JSON: " ^ body))
    | `Assoc fields -> (
      match List.assoc_opt "Items" fields with
      | None -> Error (Dynamodb_error.Malformed_response "Query response has no \"Items\" field")
      | Some (`List items) -> (
        let* items =
          List.fold_left
          (fun acc item_json ->
            let* acc = acc in
            match item_of_json item_json with Ok item -> Ok (item :: acc) | Error msg -> Error msg)
          (Ok []) items
          |> Result.map_error (fun msg -> Dynamodb_error.Malformed_response msg)
        in
        let* last_evaluated_key =
          match List.assoc_opt "LastEvaluatedKey" fields with
          | None -> Ok None
          | Some json -> (
            match item_of_json json with
            | Ok key -> Ok (Some key)
            | Error msg -> Error (Dynamodb_error.Malformed_response msg))
        in
        Ok { items = List.rev items; last_evaluated_key })
      | Some json ->
        Error (Dynamodb_error.Malformed_response ("\"Items\" is not a JSON array: " ^ Yojson.Safe.to_string json)))
    | json -> Error (Dynamodb_error.Malformed_response ("expected a JSON object, got: " ^ Yojson.Safe.to_string json))

let condition_fields state = function
  | None -> []
  | Some c ->
    let expr = compile_condition state c in
    ("ConditionExpression", `String expr) :: alias_fields state

let put_item t ?condition ~item () =
  let* () = validate_item item in
  let state = new_alias_state () in
  let body =
    build_request_body
      ([ ("TableName", `String t.config.table); ("Item", item_to_json item) ] @ condition_fields state condition)
  in
  match call t ~action:"PutItem" ~body () with
  | Error _ as e -> e
  | Ok r -> interpret_put r

let get_item t ~key =
  let* () = validate_item key in
  let body = build_request_body [ ("TableName", `String t.config.table); ("Key", item_to_json key) ] in
  match call t ~action:"GetItem" ~body () with
  | Error _ as e -> e
  | Ok r -> interpret_get r

let delete_item t ?condition ~key () =
  let* () = validate_item key in
  let state = new_alias_state () in
  let body =
    build_request_body
      ([ ("TableName", `String t.config.table); ("Key", item_to_json key) ] @ condition_fields state condition)
  in
  match call t ~action:"DeleteItem" ~body () with
  | Error _ as e -> e
  | Ok r -> interpret_delete r

let update_item t ?condition ~key ~updates () =
  if updates = [] then Error Dynamodb_error.Empty_updates
  else
    let* () = validate_item key in
    let state = new_alias_state () in
    let update_expression = compile_updates state updates in
    let condition_expression =
      match condition with Some c -> [ ("ConditionExpression", `String (compile_condition state c)) ] | None -> []
    in
    let body =
      build_request_body
        ([ ("TableName", `String t.config.table);
           ("Key", item_to_json key);
           ("UpdateExpression", `String update_expression);
         ]
        @ condition_expression @ alias_fields state)
    in
    match call t ~action:"UpdateItem" ~body () with
    | Error _ as e -> e
    | Ok r -> interpret_update r

let query_page t ?index_name ?expression_attribute_names ?exclusive_start_key ?limit
    ~key_condition_expression ~expression_attribute_values () =
  let* () = validate_item expression_attribute_values in
  let* () = match exclusive_start_key with None -> Ok () | Some key -> validate_item key in
  let* () =
    match limit with
    | Some n when n <= 0 -> Error (Dynamodb_error.Invalid_request "query limit must be positive")
    | _ -> Ok ()
  in
  let fields =
    [ ("TableName", `String t.config.table);
      ("KeyConditionExpression", `String key_condition_expression);
      ("ExpressionAttributeValues", item_to_json expression_attribute_values);
    ]
    @ (match index_name with Some n -> [ ("IndexName", `String n) ] | None -> [])
    @ (match exclusive_start_key with Some key -> [ ("ExclusiveStartKey", item_to_json key) ] | None -> [])
    @ (match limit with Some n -> [ ("Limit", `Int n) ] | None -> [])
    @
    match expression_attribute_names with
    | Some names when names <> [] ->
      [ ("ExpressionAttributeNames", `Assoc (List.map (fun (k, v) -> (k, `String v)) names)) ]
    | _ -> []
  in
  let body = build_request_body fields in
  match call t ~action:"Query" ~body () with
  | Error _ as e -> e
  | Ok r -> interpret_query_page r

let query_all t ?index_name ?expression_attribute_names ~key_condition_expression
    ~expression_attribute_values () =
  let rec loop acc exclusive_start_key =
    match
      query_page t ?index_name ?expression_attribute_names ?exclusive_start_key
        ~key_condition_expression ~expression_attribute_values ()
    with
    | Error _ as e -> e
    | Ok { items; last_evaluated_key = None } -> Ok (List.rev_append acc items)
    | Ok { items; last_evaluated_key = Some key } -> loop (List.rev_append items acc) (Some key)
  in
  loop [] None
