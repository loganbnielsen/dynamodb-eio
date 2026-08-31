let config ?(region = "us-east-1") () : Dynamodb_client.config =
  { table = "t";
    region;
    credentials =
      { source =
          Aws.Credentials.Static
            { access_key_id = "AKID"; secret_access_key = "SECRET"; session_token = None };
        region;
      };
  }

let client env ?region () =
  Dynamodb_client.create ~net:env#net ~clock:env#clock ~fs:env#fs (config ?region ())

let test_get_item_rejects_crlf_region () =
  Eio_main.run @@ fun env ->
  let client = client env ~region:"us-east-1\r\nX-Injected: 1" () in
  Alcotest.(check bool) "CRLF in region is rejected before a request" true
    (match Dynamodb_client.get_item client ~key:[] with
     | Error (Invalid_config _) -> true
     | _ -> false)

let test_put_item_rejects_duplicate_attribute () =
  Eio_main.run @@ fun env ->
  let client = client env () in
  Alcotest.(check bool) "duplicate attribute rejected before a request" true
    (match
       Dynamodb_client.put_item client
         ~item:[ ("id", Dynamodb_value.S "a"); ("id", Dynamodb_value.S "b") ] ()
     with
     | Error (Invalid_request _) -> true
     | _ -> false)

let test_query_page_rejects_non_positive_limit () =
  Eio_main.run @@ fun env ->
  let client = client env () in
  Alcotest.(check bool) "limit rejected before a request" true
    (match
       Dynamodb_client.query_page client
         ~limit:0
         ~key_condition:(Dynamodb_client.Pk_equals { pk_attribute = "pk"; pk = Dynamodb_value.S "ORG#1" })
         ()
     with
     | Error (Invalid_request _) -> true
     | _ -> false)

let test_update_item_rejects_empty_updates () =
  Eio_main.run @@ fun env ->
  let client = client env () in
  Alcotest.(check bool) "Empty_updates, no request built" true
    (Dynamodb_client.update_item client ~key:[] ~updates:[] () = Error Empty_updates)

let () =
  Alcotest.run "dynamodb_client"
    [ ( "public validation",
        [ Alcotest.test_case "get_item rejects CRLF region" `Quick test_get_item_rejects_crlf_region;
          Alcotest.test_case "put_item rejects duplicate attributes" `Quick
            test_put_item_rejects_duplicate_attribute;
          Alcotest.test_case "query_page rejects non-positive limit" `Quick
            test_query_page_rejects_non_positive_limit;
          Alcotest.test_case "update_item rejects empty updates" `Quick
            test_update_item_rejects_empty_updates;
        ] );
    ]
