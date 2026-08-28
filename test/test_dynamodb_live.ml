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

let with_live_item ~net ~clock config item f =
  match Dynamodb_client.put_item ~net ~clock config ~item () with
  | Error e -> Alcotest.failf "PutItem failed: %s" (Dynamodb_error.to_string e)
  | Ok () ->
    Fun.protect
      ~finally:(fun () ->
        match Dynamodb_client.delete_item ~net ~clock config ~key:live_key () with
        | Ok () | Error _ -> ())
      (fun () -> f ())

let test_put_get_delete_roundtrip () =
  if not (live_enabled ()) then
    Printf.printf "[skip] DYNAMODB_EIO_LIVE not set to 1 — skipping live DynamoDB smoke test\n%!"
  else
    Eio_main.run @@ fun env ->
    let net = env#net and clock = env#clock in
    let config = config () in
    let item = live_key @ [ ("count", Dynamodb_value.N "42") ] in
    with_live_item ~net ~clock config item (fun () ->
        match Dynamodb_client.get_item ~net ~clock config ~key:live_key with
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
    let config = config () in
    let missing_key = [ ("pk", Dynamodb_value.S "sun-live-test#does-not-exist"); ("sk", Dynamodb_value.S "item") ] in
    match Dynamodb_client.get_item ~net:env#net ~clock:env#clock config ~key:missing_key with
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
    let net = env#net and clock = env#clock in
    let config = config () in
    let item = live_key @ [ ("version", Dynamodb_value.N "1"); ("status", Dynamodb_value.S "pending") ] in
    with_live_item ~net ~clock config item (fun () ->
        (match
           Dynamodb_client.update_item ~net ~clock config ~condition:(Equals ("version", Dynamodb_value.N "1"))
             ~key:live_key
             ~updates:[ Increment ("version", "1"); Set ("status", Dynamodb_value.S "shipped") ]
             ()
         with
        | Error e -> Alcotest.failf "conditional update expected to succeed, got: %s" (Dynamodb_error.to_string e)
        | Ok () -> ());
        (match Dynamodb_client.get_item ~net ~clock config ~key:live_key with
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
          Dynamodb_client.update_item ~net ~clock config ~condition:(Equals ("version", Dynamodb_value.N "1"))
            ~key:live_key
            ~updates:[ Increment ("version", "1") ]
            ()
        with
        | Error Conditional_check_failed -> ()
        | Error e -> Alcotest.failf "expected Conditional_check_failed, got: %s" (Dynamodb_error.to_string e)
        | Ok () -> Alcotest.fail "stale condition should not have matched")

let () =
  Alcotest.run "dynamodb_live"
    [ ( "smoke",
        [ Alcotest.test_case "put/get/delete round trip" `Quick test_put_get_delete_roundtrip;
          Alcotest.test_case "known-missing key returns None" `Quick test_missing_key_returns_none;
          Alcotest.test_case "conditional update: CAS succeeds then fails on stale version" `Quick
            test_conditional_update_cas;
        ] );
    ]
