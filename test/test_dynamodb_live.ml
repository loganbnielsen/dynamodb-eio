(* Live DynamoDB smoke test. Skipped entirely unless DYNAMODB_EIO_LIVE=1 is
   set: the default `dune runtest` must never touch a real AWS account or
   table.

   Required environment: DYNAMODB_EIO_LIVE=1, DYNAMODB_EIO_LIVE_TABLE=<a table
   you control, primary key: partition "pk" (S), sort "sk" (S)>, plus
   credentials Aws_credentials's Env_chain already knows how to read
   (AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY, optionally AWS_SESSION_TOKEN).
   AWS_REGION is optional, defaulting to us-east-1.

   Writes exactly one item per test run under a sun-live-test# prefixed key
   and deletes it in Fun.protect, so a failed assertion still cleans up.

   Use a table dedicated to this test, not one holding real data — that
   makes table-level ARN scoping sufficient without needing an item-level
   condition. Minimal IAM policy for the credentials used here:

   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "DynamoDBLiveTestOnly",
         "Effect": "Allow",
         "Action": ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:DeleteItem", "dynamodb:UpdateItem"],
         "Resource": "arn:aws:dynamodb:YOUR_REGION:YOUR_ACCOUNT_ID:table/YOUR_TABLE"
       }
     ]
   } *)

let live_enabled () = Sys.getenv_opt "DYNAMODB_EIO_LIVE" = Some "1"

let region () = Option.value (Sys.getenv_opt "AWS_REGION") ~default:"us-east-1"

let config () =
  let region = region () in
  { Dynamodb_client.table = Option.value (Sys.getenv_opt "DYNAMODB_EIO_LIVE_TABLE") ~default:"";
    region;
    credentials = Aws_credentials.of_env ~region ();
  }

let live_key = [ ("pk", Dynamodb_value.S "sun-live-test#s3-eio-smoke"); ("sk", Dynamodb_value.S "item") ]

let with_live_item client item f =
  match Dynamodb_client.put_item client ~item () with
  | Error e -> Alcotest.failf "PutItem failed: %s" (Dynamodb_error.to_string e)
  | Ok () ->
    Fun.protect
      ~finally:(fun () ->
        match Dynamodb_client.delete_item client ~key:live_key () with
        | Ok () | Error _ -> ())
      (fun () -> f ())

let test_put_get_delete_roundtrip () =
  if not (live_enabled ()) then
    Printf.printf "[skip] DYNAMODB_EIO_LIVE not set to 1 — skipping live DynamoDB smoke test\n%!"
  else
    Eio_main.run @@ fun env ->
    let client = Dynamodb_client.create ~net:env#net ~clock:env#clock ~fs:env#fs (config ()) in
    let item = live_key @ [ ("count", Dynamodb_value.N "42") ] in
    with_live_item client item (fun () ->
        match Dynamodb_client.get_item client ~key:live_key with
        | Error e -> Alcotest.failf "GetItem failed: %s" (Dynamodb_error.to_string e)
        | Ok None -> Alcotest.fail "expected the item we just put"
        | Ok (Some got) ->
          Alcotest.(check bool) "count round-tripped" true
            (List.assoc_opt "count" got = Some (Dynamodb_value.N "42")))

let test_missing_key_returns_none () =
  if not (live_enabled ()) then
    Printf.printf "[skip] DYNAMODB_EIO_LIVE not set to 1 — skipping live DynamoDB smoke test\n%!"
  else
    Eio_main.run @@ fun env ->
    let client = Dynamodb_client.create ~net:env#net ~clock:env#clock ~fs:env#fs (config ()) in
    let missing_key = [ ("pk", Dynamodb_value.S "sun-live-test#does-not-exist"); ("sk", Dynamodb_value.S "item") ] in
    match Dynamodb_client.get_item client ~key:missing_key with
    | Ok None -> ()
    | Ok (Some _) -> Alcotest.fail "expected the known-missing key to return None"
    | Error e -> Alcotest.failf "GetItem failed: %s" (Dynamodb_error.to_string e)

(* Version-stamp CAS round trip: update_item's ConditionExpression is the
   whole reason update_item accepts one at all — a bare atomic Increment
   would already be race-free without a condition, but a real optimistic-lock
   pattern (update iff the version I last read still matches) needs a
   compare-and-swap, not just an atomic op. *)
let test_conditional_update_cas () =
  if not (live_enabled ()) then
    Printf.printf "[skip] DYNAMODB_EIO_LIVE not set to 1 — skipping live DynamoDB smoke test\n%!"
  else
    Eio_main.run @@ fun env ->
    let client = Dynamodb_client.create ~net:env#net ~clock:env#clock ~fs:env#fs (config ()) in
    let item = live_key @ [ ("version", Dynamodb_value.N "1"); ("status", Dynamodb_value.S "pending") ] in
    with_live_item client item (fun () ->
        (match
           Dynamodb_client.update_item client ~condition:(Equals ("version", Dynamodb_value.N "1"))
             ~key:live_key
             ~updates:[ Increment ("version", "1"); Set ("status", Dynamodb_value.S "shipped") ]
             ()
         with
        | Error e -> Alcotest.failf "conditional update expected to succeed, got: %s" (Dynamodb_error.to_string e)
        | Ok () -> ());
        (match Dynamodb_client.get_item client ~key:live_key with
        | Error e -> Alcotest.failf "GetItem failed: %s" (Dynamodb_error.to_string e)
        | Ok None -> Alcotest.fail "expected the item to still exist"
        | Ok (Some got) ->
          Alcotest.(check bool) "version incremented" true
            (List.assoc_opt "version" got = Some (Dynamodb_value.N "2"));
          Alcotest.(check bool) "status updated" true
            (List.assoc_opt "status" got = Some (Dynamodb_value.S "shipped")));
        (* Same condition again, now stale (version is 2, not 1) — must fail,
           not silently clobber a concurrent writer's update. *)
        match
          Dynamodb_client.update_item client ~condition:(Equals ("version", Dynamodb_value.N "1"))
            ~key:live_key
            ~updates:[ Increment ("version", "1") ]
            ()
        with
        | Error Conditional_check_failed -> ()
        | Error e -> Alcotest.failf "expected Conditional_check_failed, got: %s" (Dynamodb_error.to_string e)
        | Ok () -> Alcotest.fail "stale condition should not have matched")

(* "Create iff missing" — the other named idiom conditional writes exist for,
   distinct from update_item's version-stamp CAS: Attribute_not_exists on
   put_item succeeds once, then fails once the item exists, so two
   concurrent "create if not there" callers can't both believe they won. *)
let test_conditional_put_create_iff_missing () =
  if not (live_enabled ()) then
    Printf.printf "[skip] DYNAMODB_EIO_LIVE not set to 1 — skipping live DynamoDB smoke test\n%!"
  else
    Eio_main.run @@ fun env ->
    let client = Dynamodb_client.create ~net:env#net ~clock:env#clock ~fs:env#fs (config ()) in
    let key = [ ("pk", Dynamodb_value.S "sun-live-test#dynamodb-eio-create-iff-missing"); ("sk", Dynamodb_value.S "item") ] in
    let item = key @ [ ("created_by", Dynamodb_value.S "first-writer") ] in
    Fun.protect
      ~finally:(fun () -> ignore (Dynamodb_client.delete_item client ~key ()))
      (fun () ->
        (match Dynamodb_client.put_item client ~condition:(Attribute_not_exists "pk") ~item () with
        | Error e -> Alcotest.failf "first create-iff-missing put expected to succeed, got: %s" (Dynamodb_error.to_string e)
        | Ok () -> ());
        (* Same condition again — must fail now that the item exists, not silently
           overwrite whichever writer actually created it first. *)
        let second_item = key @ [ ("created_by", Dynamodb_value.S "second-writer") ] in
        match
          Dynamodb_client.put_item client ~condition:(Attribute_not_exists "pk") ~item:second_item ()
        with
        | Error Conditional_check_failed -> ()
        | Error e -> Alcotest.failf "expected Conditional_check_failed, got: %s" (Dynamodb_error.to_string e)
        | Ok () -> Alcotest.fail "second create-iff-missing put should not have succeeded")

(* Remove/Add/Delete are the three update_op variants test_conditional_update_cas
   doesn't touch (it only exercises Increment/Set) — Remove drops a scalar
   attribute entirely, Add/Delete do set-union/set-difference on a string-set
   attribute. All three compile through the same alias allocator as Set/Increment;
   this is the only test that reaches them at all. *)
let test_update_remove_add_delete () =
  if not (live_enabled ()) then
    Printf.printf "[skip] DYNAMODB_EIO_LIVE not set to 1 — skipping live DynamoDB smoke test\n%!"
  else
    Eio_main.run @@ fun env ->
    let client = Dynamodb_client.create ~net:env#net ~clock:env#clock ~fs:env#fs (config ()) in
    let item = live_key @ [ ("scratch", Dynamodb_value.S "drop-me"); ("tags", Dynamodb_value.Ss [ "a"; "b" ]) ] in
    with_live_item client item (fun () ->
        (match
           Dynamodb_client.update_item client ~key:live_key
             ~updates:
               [ Remove "scratch";
                 Add ("tags", Dynamodb_value.Ss [ "c" ]);
               ]
             ()
         with
        | Error e -> Alcotest.failf "remove+add update expected to succeed, got: %s" (Dynamodb_error.to_string e)
        | Ok () -> ());
        (match Dynamodb_client.get_item client ~key:live_key with
        | Error e -> Alcotest.failf "GetItem failed: %s" (Dynamodb_error.to_string e)
        | Ok None -> Alcotest.fail "expected the item to still exist"
        | Ok (Some got) ->
          Alcotest.(check bool) "scratch attribute removed" true (List.assoc_opt "scratch" got = None);
          Alcotest.(check bool) "tags gained the added element" true
            (match List.assoc_opt "tags" got with
             | Some (Dynamodb_value.Ss tags) -> List.sort compare tags = [ "a"; "b"; "c" ]
             | _ -> false));
        match
          Dynamodb_client.update_item client ~key:live_key ~updates:[ Delete ("tags", Dynamodb_value.Ss [ "a" ]) ] ()
        with
        | Error e -> Alcotest.failf "delete-from-set update expected to succeed, got: %s" (Dynamodb_error.to_string e)
        | Ok () -> (
          match Dynamodb_client.get_item client ~key:live_key with
          | Error e -> Alcotest.failf "GetItem failed: %s" (Dynamodb_error.to_string e)
          | Ok None -> Alcotest.fail "expected the item to still exist"
          | Ok (Some got) ->
            Alcotest.(check bool) "tags lost the deleted element" true
              (match List.assoc_opt "tags" got with
               | Some (Dynamodb_value.Ss tags) -> List.sort compare tags = [ "b"; "c" ]
               | _ -> false)))

(* And/Or/Not_equals are the boolean-composition side of `condition` that
   test_conditional_update_cas/test_conditional_put_create_iff_missing don't
   reach (both only use a bare Equals/Attribute_not_exists). Exercises the
   recursive compile_condition branches and confirms operator precedence
   round-trips through DynamoDB's own expression grammar as intended:
   "(status <> shipped) AND (version = 1)". *)
let test_condition_and_or_not_equals () =
  if not (live_enabled ()) then
    Printf.printf "[skip] DYNAMODB_EIO_LIVE not set to 1 — skipping live DynamoDB smoke test\n%!"
  else
    Eio_main.run @@ fun env ->
    let client = Dynamodb_client.create ~net:env#net ~clock:env#clock ~fs:env#fs (config ()) in
    let item = live_key @ [ ("version", Dynamodb_value.N "1"); ("status", Dynamodb_value.S "pending") ] in
    let and_condition =
      Dynamodb_client.And
        (Not_equals ("status", Dynamodb_value.S "shipped"), Equals ("version", Dynamodb_value.N "1"))
    in
    with_live_item client item (fun () ->
        (match
           Dynamodb_client.update_item client ~condition:and_condition ~key:live_key
             ~updates:[ Set ("status", Dynamodb_value.S "shipped") ]
             ()
         with
        | Error e -> Alcotest.failf "AND/Not_equals condition expected to hold, got: %s" (Dynamodb_error.to_string e)
        | Ok () -> ());
        (* Now status = "shipped", so the same AND condition's Not_equals half is
           false; an Or against an unrelated-but-true clause must still let it
           through — Or's whole point is "either side holding is enough". *)
        let or_condition =
          Dynamodb_client.Or
            (Not_equals ("status", Dynamodb_value.S "shipped"), Equals ("version", Dynamodb_value.N "1"))
        in
        match
          Dynamodb_client.update_item client ~condition:or_condition ~key:live_key
            ~updates:[ Increment ("version", "1") ]
            ()
        with
        | Error e -> Alcotest.failf "OR condition expected to hold via its true half, got: %s" (Dynamodb_error.to_string e)
        | Ok () -> ())

(* No live coverage of query_page/query_all existed before key_condition
   replaced the raw key_condition_expression/expression_attribute_* triple
   (a caller previously matched a `#pk`/`:pk` naming convention by hand,
   the class of mismatch key_condition now makes impossible to construct).
   Confirms compile_key_condition's output is not just well-typed but
   actually valid DynamoDB KeyConditionExpression syntax that returns the
   right item, for both shapes: pk-only and pk+sk. *)
let test_query_by_key_condition () =
  if not (live_enabled ()) then
    Printf.printf "[skip] DYNAMODB_EIO_LIVE not set to 1 — skipping live DynamoDB smoke test\n%!"
  else
    Eio_main.run @@ fun env ->
    let client = Dynamodb_client.create ~net:env#net ~clock:env#clock ~fs:env#fs (config ()) in
    let item = live_key @ [ ("note", Dynamodb_value.S "query-test") ] in
    with_live_item client item (fun () ->
        let pk =
          match List.assoc_opt "pk" live_key with
          | Some v -> v
          | None -> Alcotest.fail "live_key missing pk"
        in
        let sk =
          match List.assoc_opt "sk" live_key with
          | Some v -> v
          | None -> Alcotest.fail "live_key missing sk"
        in
        (match
           Dynamodb_client.query_all client
             ~key_condition:(Dynamodb_client.Pk_equals { pk_attribute = "pk"; pk }) ()
         with
         | Error e -> Alcotest.failf "Pk_equals query failed: %s" (Dynamodb_error.to_string e)
         | Ok items ->
           Alcotest.(check bool) "pk-only query finds the item" true
             (List.exists (fun i -> i = item) items));
        match
          Dynamodb_client.query_all client
            ~key_condition:(Dynamodb_client.Pk_and_sk_equals
              { pk_attribute = "pk"; pk; sk_attribute = "sk"; sk }) ()
        with
        | Error e -> Alcotest.failf "Pk_and_sk_equals query failed: %s" (Dynamodb_error.to_string e)
        | Ok items ->
          Alcotest.(check bool) "pk+sk query finds the exact item" true
            (List.exists (fun i -> i = item) items))

let () =
  Alcotest.run "dynamodb_live"
    [ ( "smoke",
        [ Alcotest.test_case "put/get/delete round trip" `Quick test_put_get_delete_roundtrip;
          Alcotest.test_case "known-missing key returns None" `Quick test_missing_key_returns_none;
          Alcotest.test_case "conditional update: CAS succeeds then fails on stale version" `Quick
            test_conditional_update_cas;
          Alcotest.test_case "conditional put: create-iff-missing succeeds then fails once it exists" `Quick
            test_conditional_put_create_iff_missing;
          Alcotest.test_case "update_item: Remove/Add/Delete" `Quick test_update_remove_add_delete;
          Alcotest.test_case "condition: And/Or/Not_equals" `Quick test_condition_and_or_not_equals;
          Alcotest.test_case "query by key_condition (Pk_equals and Pk_and_sk_equals)" `Quick
            test_query_by_key_condition;
        ] );
    ]
