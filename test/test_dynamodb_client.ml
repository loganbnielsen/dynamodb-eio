(* reclassify_transport_result restores Ok on non-2xx so a
   ResourceNotFoundException still classifies as Resource_not_found. *)
let test_reclassify_then_interpret_get () =
  let body = {|{"__type":"com.amazonaws.dynamodb.v20120810#ResourceNotFoundException","message":"x"}|} in
  let transport_result : (int * (string * string) list * string, Aws_error.t) result =
    Error (Aws_error.Http_error (400, body))
  in
  match Result.bind (Dynamodb_client.reclassify_transport_result transport_result) Dynamodb_client.interpret_get with
  | Error Resource_not_found -> ()
  | Error e -> Alcotest.failf "expected Resource_not_found, got %s" (Dynamodb_error.to_string e)
  | Ok _ -> Alcotest.fail "expected an error"

let test_reclassify_passes_through_genuine_transport_errors () =
  let transport_result : (int * (string * string) list * string, Aws_error.t) result =
    Error (Aws_error.Network_error "connection refused")
  in
  Alcotest.(check bool) "a genuine transport error (not an HTTP status) stays Dynamodb_error.Aws" true
    (match Dynamodb_client.reclassify_transport_result transport_result with Error (Aws _) -> true | _ -> false)

let test_reclassify_passes_through_success () =
  let transport_result : (int * (string * string) list * string, Aws_error.t) result = Ok (200, [], "{}") in
  Alcotest.(check bool) "a 2xx Ok passes through unchanged" true
    (Dynamodb_client.reclassify_transport_result transport_result = Ok (200, [], "{}"))

let test_validate_config_rejects_crlf_in_region () =
  let config =
    { Dynamodb_client.table = "t"; region = "us-east-1\r\nX-Injected: 1";
      credentials = Aws_credentials.of_env ~region:"us-east-1" () }
  in
  Alcotest.(check bool) "CRLF in region is rejected" true
    (match Dynamodb_client.validate_config config with Error (Invalid_config _) -> true | _ -> false)

let test_validate_config_accepts_normal_config () =
  let config =
    { Dynamodb_client.table = "t"; region = "us-east-1"; credentials = Aws_credentials.of_env ~region:"us-east-1" () }
  in
  Alcotest.(check bool) "ordinary config passes" true (Result.is_ok (Dynamodb_client.validate_config config))

(* interpret_* mappers are pure — no network/TLS needed to test how a
   (status, headers, body) triple maps to a result. *)

let test_interpret_put_success () =
  Alcotest.(check bool) "200 -> Ok ()" true (Result.is_ok (Dynamodb_client.interpret_put (200, [], "")))

let test_interpret_put_error () =
  let body = {|{"__type":"com.amazonaws.dynamodb.v20120810#ResourceNotFoundException","message":"x"}|} in
  Alcotest.(check bool) "400 -> Error Resource_not_found" true
    (match Dynamodb_client.interpret_put (400, [], body) with Error Resource_not_found -> true | _ -> false)

let test_interpret_get_item_present () =
  let body = {|{"Item":{"id":{"S":"abc"},"count":{"N":"5"}}}|} in
  match Dynamodb_client.interpret_get (200, [], body) with
  | Error e -> Alcotest.fail (Dynamodb_error.to_string e)
  | Ok None -> Alcotest.fail "expected Some item"
  | Ok (Some item) ->
    Alcotest.(check bool) "id" true (List.assoc_opt "id" item = Some (Dynamodb_value.S "abc"));
    Alcotest.(check bool) "count" true (List.assoc_opt "count" item = Some (Dynamodb_value.N "5"))

let test_interpret_get_item_missing () =
  (* GetItem returns HTTP 200 with no "Item" field when the key doesn't
     exist — not a 404, unlike S3's GetObject. *)
  match Dynamodb_client.interpret_get (200, [], "{}") with
  | Ok None -> ()
  | Ok (Some _) -> Alcotest.fail "expected None"
  | Error e -> Alcotest.fail (Dynamodb_error.to_string e)

let test_interpret_get_malformed_json () =
  Alcotest.(check bool) "invalid JSON -> Malformed_response" true
    (match Dynamodb_client.interpret_get (200, [], "not json") with
     | Error (Malformed_response _) -> true
     | _ -> false)

let test_interpret_delete_success () =
  Alcotest.(check bool) "200 -> Ok ()" true (Result.is_ok (Dynamodb_client.interpret_delete (200, [], "")))

let test_interpret_query_items () =
  let body = {|{"Items":[{"id":{"S":"a"}},{"id":{"S":"b"}}],"Count":2}|} in
  match Dynamodb_client.interpret_query (200, [], body) with
  | Error e -> Alcotest.fail (Dynamodb_error.to_string e)
  | Ok items ->
    Alcotest.(check int) "two items" 2 (List.length items);
    Alcotest.(check bool) "first item" true (List.assoc_opt "id" (List.nth items 0) = Some (Dynamodb_value.S "a"))

let test_interpret_query_empty () =
  match Dynamodb_client.interpret_query (200, [], {|{"Items":[],"Count":0}|}) with
  | Ok [] -> ()
  | Ok _ -> Alcotest.fail "expected an empty list"
  | Error e -> Alcotest.fail (Dynamodb_error.to_string e)

let test_item_to_json_and_back () =
  let item = [ ("id", Dynamodb_value.S "abc"); ("count", Dynamodb_value.N "5"); ("active", Dynamodb_value.Bool true) ] in
  let json = Dynamodb_client.item_to_json item in
  match Dynamodb_client.item_of_json json with
  | Error msg -> Alcotest.fail msg
  | Ok item' -> Alcotest.(check bool) "round trips" true (item = item')

let test_build_request_body_is_valid_json () =
  let body = Dynamodb_client.build_request_body [ ("TableName", `String "t") ] in
  match Yojson.Safe.from_string body with
  | `Assoc [ ("TableName", `String "t") ] -> ()
  | _ -> Alcotest.failf "unexpected body: %s" body

(* condition/update_op compilation — pure, no network needed. *)

let test_compile_condition_attribute_exists () =
  let state = Dynamodb_client.new_alias_state () in
  let expr = Dynamodb_client.compile_condition state (Attribute_exists "pk") in
  Alcotest.(check bool) "attribute_exists(#n0)" true (expr = "attribute_exists(#n0)")

let test_compile_condition_attribute_not_exists () =
  let state = Dynamodb_client.new_alias_state () in
  let expr = Dynamodb_client.compile_condition state (Attribute_not_exists "pk") in
  Alcotest.(check bool) "attribute_not_exists(#n0)" true (expr = "attribute_not_exists(#n0)")

let test_compile_condition_equals () =
  let state = Dynamodb_client.new_alias_state () in
  let expr = Dynamodb_client.compile_condition state (Equals ("version", Dynamodb_value.N "1")) in
  Alcotest.(check bool) "#n0 = :v0" true (expr = "#n0 = :v0");
  Alcotest.(check bool) "aliases version and N 1" true
    (Dynamodb_client.alias_fields state
    = [ ("ExpressionAttributeNames", `Assoc [ ("#n0", `String "version") ]);
        ("ExpressionAttributeValues", `Assoc [ (":v0", `Assoc [ ("N", `String "1") ]) ]);
      ])

let test_compile_condition_not_equals () =
  let state = Dynamodb_client.new_alias_state () in
  let expr = Dynamodb_client.compile_condition state (Not_equals ("status", Dynamodb_value.S "done")) in
  Alcotest.(check bool) "#n0 <> :v0" true (expr = "#n0 <> :v0")

let test_compile_condition_and_or_nest () =
  let state = Dynamodb_client.new_alias_state () in
  let expr =
    Dynamodb_client.compile_condition state
      (Or (And (Attribute_exists "pk", Equals ("v", Dynamodb_value.N "1")), Attribute_not_exists "locked"))
  in
  Alcotest.(check bool) "parenthesized AND/OR nesting (both operands always wrapped, harmless on a leaf)" true
    (expr = "((attribute_exists(#n0)) AND (#n1 = :v0)) OR (attribute_not_exists(#n2))")

let test_compile_updates_groups_by_keyword () =
  let state = Dynamodb_client.new_alias_state () in
  let expr =
    Dynamodb_client.compile_updates state
      [ Set ("status", Dynamodb_value.S "shipped"); Remove "temp"; Add ("count", Dynamodb_value.N "1");
        Delete ("tags", Dynamodb_value.Ss [ "x" ]);
      ]
  in
  Alcotest.(check bool) "one clause per keyword, in SET/REMOVE/ADD/DELETE order" true
    (expr = "SET #n0 = :v0 REMOVE #n1 ADD #n2 :v1 DELETE #n3 :v2")

let test_compile_updates_multiple_sets_join_with_comma () =
  let state = Dynamodb_client.new_alias_state () in
  let expr =
    Dynamodb_client.compile_updates state
      [ Set ("a", Dynamodb_value.S "x"); Set ("b", Dynamodb_value.S "y") ]
  in
  Alcotest.(check bool) "SET #n0 = :v0, #n1 = :v1" true (expr = "SET #n0 = :v0, #n1 = :v1")

let test_compile_updates_increment_reuses_same_alias_both_sides () =
  let state = Dynamodb_client.new_alias_state () in
  let expr = Dynamodb_client.compile_updates state [ Increment ("count", "3") ] in
  Alcotest.(check bool) "SET #n0 = #n0 + :v0" true (expr = "SET #n0 = #n0 + :v0");
  Alcotest.(check bool) "increment value encoded as N, not S (decimal-string, not int)" true
    (Dynamodb_client.alias_fields state
    = [ ("ExpressionAttributeNames", `Assoc [ ("#n0", `String "count") ]);
        ("ExpressionAttributeValues", `Assoc [ (":v0", `Assoc [ ("N", `String "3") ]) ]);
      ])

(* The property the design review specifically called out: a condition and an
   update sharing one alias_state must never collide, even when both
   reference the same attribute name. *)
let test_shared_alias_state_no_collision_between_condition_and_update () =
  let state = Dynamodb_client.new_alias_state () in
  let cond_expr = Dynamodb_client.compile_condition state (Equals ("version", Dynamodb_value.N "1")) in
  let update_expr = Dynamodb_client.compile_updates state [ Increment ("version", "1") ] in
  Alcotest.(check bool) "condition got #n0/:v0" true (cond_expr = "#n0 = :v0");
  Alcotest.(check bool) "update got its own #n1 (not reusing #n0)" true (update_expr = "SET #n1 = #n1 + :v1");
  match Dynamodb_client.alias_fields state with
  | [ ("ExpressionAttributeNames", `Assoc names); ("ExpressionAttributeValues", `Assoc values) ] ->
    Alcotest.(check int) "two distinct name aliases accumulated" 2 (List.length names);
    Alcotest.(check int) "two distinct value aliases accumulated" 2 (List.length values)
  | fields -> Alcotest.failf "unexpected alias_fields shape: %s" (Yojson.Safe.to_string (`Assoc fields))

let test_alias_fields_empty_when_nothing_aliased () =
  let state = Dynamodb_client.new_alias_state () in
  Alcotest.(check bool) "no fields when state is fresh" true (Dynamodb_client.alias_fields state = [])

let test_alias_fields_present_after_compiling () =
  let state = Dynamodb_client.new_alias_state () in
  let _ = Dynamodb_client.compile_condition state (Attribute_exists "pk") in
  let fields = Dynamodb_client.alias_fields state in
  Alcotest.(check bool) "ExpressionAttributeNames present, no values needed for this condition" true
    (match fields with [ ("ExpressionAttributeNames", _) ] -> true | _ -> false)

let test_update_item_rejects_empty_updates () =
  let config = { Dynamodb_client.table = "t"; region = "us-east-1"; credentials = Aws_credentials.of_env ~region:"us-east-1" () } in
  Eio_main.run @@ fun env ->
  Alcotest.(check bool) "Empty_updates, no request built" true
    (Dynamodb_client.update_item ~net:env#net ~clock:env#clock config ~key:[] ~updates:[] () = Error Empty_updates)

let () =
  Alcotest.run "dynamodb_client"
    [ ( "reclassify_transport_result",
        [ Alcotest.test_case "reclassified 400 -> interpret_get -> Resource_not_found" `Quick
            test_reclassify_then_interpret_get;
          Alcotest.test_case "genuine transport error stays Aws" `Quick
            test_reclassify_passes_through_genuine_transport_errors;
          Alcotest.test_case "2xx Ok passes through unchanged" `Quick test_reclassify_passes_through_success;
        ] );
      ( "validate_config",
        [ Alcotest.test_case "rejects CRLF in region" `Quick test_validate_config_rejects_crlf_in_region;
          Alcotest.test_case "accepts an ordinary config" `Quick test_validate_config_accepts_normal_config;
        ] );
      ( "interpret",
        [ Alcotest.test_case "put: success" `Quick test_interpret_put_success;
          Alcotest.test_case "put: error" `Quick test_interpret_put_error;
          Alcotest.test_case "get: item present" `Quick test_interpret_get_item_present;
          Alcotest.test_case "get: item missing (200, no Item field)" `Quick test_interpret_get_item_missing;
          Alcotest.test_case "get: malformed JSON" `Quick test_interpret_get_malformed_json;
          Alcotest.test_case "delete: success" `Quick test_interpret_delete_success;
          Alcotest.test_case "query: items" `Quick test_interpret_query_items;
          Alcotest.test_case "query: empty" `Quick test_interpret_query_empty;
        ] );
      ( "item encoding",
        [ Alcotest.test_case "item_to_json / item_of_json round trip" `Quick test_item_to_json_and_back;
          Alcotest.test_case "build_request_body produces valid JSON" `Quick test_build_request_body_is_valid_json;
        ] );
      ( "compile_condition",
        [ Alcotest.test_case "Attribute_exists" `Quick test_compile_condition_attribute_exists;
          Alcotest.test_case "Attribute_not_exists" `Quick test_compile_condition_attribute_not_exists;
          Alcotest.test_case "Equals" `Quick test_compile_condition_equals;
          Alcotest.test_case "Not_equals" `Quick test_compile_condition_not_equals;
          Alcotest.test_case "And/Or nest with parens" `Quick test_compile_condition_and_or_nest;
        ] );
      ( "compile_updates",
        [ Alcotest.test_case "groups by keyword: SET/REMOVE/ADD/DELETE" `Quick test_compile_updates_groups_by_keyword;
          Alcotest.test_case "multiple SETs join with comma" `Quick test_compile_updates_multiple_sets_join_with_comma;
          Alcotest.test_case "Increment reuses one alias on both sides of +" `Quick
            test_compile_updates_increment_reuses_same_alias_both_sides;
        ] );
      ( "shared alias_state",
        [ Alcotest.test_case "condition + update never collide on #n/:v" `Quick
            test_shared_alias_state_no_collision_between_condition_and_update;
          Alcotest.test_case "alias_fields empty on a fresh state" `Quick test_alias_fields_empty_when_nothing_aliased;
          Alcotest.test_case "alias_fields present after compiling" `Quick test_alias_fields_present_after_compiling;
        ] );
      ("update_item", [ Alcotest.test_case "rejects an empty updates list" `Quick test_update_item_rejects_empty_updates ]);
    ]
