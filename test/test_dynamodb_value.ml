let round_trip name v =
  let json = Dynamodb_value.to_json v in
  match Dynamodb_value.of_json json with
  | Error msg -> Alcotest.failf "%s: round trip failed: %s (json: %s)" name msg (Yojson.Safe.to_string json)
  | Ok v' -> Alcotest.(check bool) (name ^ ": round trips") true (v = v')

let test_s () = round_trip "S" (Dynamodb_value.S "hello")
let test_n () = round_trip "N" (Dynamodb_value.N "12345678901234567890")  (* precision-sensitive: stays a string *)
let test_b () = round_trip "B" (Dynamodb_value.B "\x00\x01\xff binary \x02")
let test_bool () = round_trip "Bool" (Dynamodb_value.Bool true)
let test_null () = round_trip "Null" Dynamodb_value.Null
let test_ss () = round_trip "Ss" (Dynamodb_value.Ss [ "a"; "b"; "c" ])
let test_ns () = round_trip "Ns" (Dynamodb_value.Ns [ "1"; "2" ])
let test_bs () = round_trip "Bs" (Dynamodb_value.Bs [ "\x00\x01"; "\x02\x03" ])
let test_l () = round_trip "L" (Dynamodb_value.L [ S "a"; N "1"; Bool false ])
let test_m () = round_trip "M" (Dynamodb_value.M [ ("name", Dynamodb_value.S "x"); ("age", Dynamodb_value.N "30") ])

let test_nested () =
  round_trip "nested M/L"
    (Dynamodb_value.M
       [ ("tags", Dynamodb_value.L [ S "a"; S "b" ]);
         ("meta", Dynamodb_value.M [ ("nested", Dynamodb_value.Bool true) ]);
       ])

let test_exact_json_shape () =
  Alcotest.(check string) "S encodes as a single-key {\"S\": ...} object"
    {|{"S":"foo"}|}
    (Yojson.Safe.to_string (Dynamodb_value.to_json (S "foo")))

let test_of_json_rejects_bare_scalar () =
  Alcotest.(check bool) "a bare JSON string (not wrapped in {\"S\": ...}) is rejected" true
    (match Dynamodb_value.of_json (`String "foo") with Error _ -> true | Ok _ -> false)

let test_of_json_rejects_invalid_base64 () =
  Alcotest.(check bool) "invalid base64 in B is rejected" true
    (match Dynamodb_value.of_json (`Assoc [ ("B", `String "not valid base64!!!") ]) with
     | Error _ -> true
     | Ok _ -> false)

let () =
  Alcotest.run "dynamodb_value"
    [ ( "round_trip",
        [ Alcotest.test_case "S" `Quick test_s;
          Alcotest.test_case "N" `Quick test_n;
          Alcotest.test_case "B" `Quick test_b;
          Alcotest.test_case "Bool" `Quick test_bool;
          Alcotest.test_case "Null" `Quick test_null;
          Alcotest.test_case "Ss" `Quick test_ss;
          Alcotest.test_case "Ns" `Quick test_ns;
          Alcotest.test_case "Bs" `Quick test_bs;
          Alcotest.test_case "L" `Quick test_l;
          Alcotest.test_case "M" `Quick test_m;
          Alcotest.test_case "nested M/L" `Quick test_nested;
        ] );
      ( "encoding",
        [ Alcotest.test_case "exact JSON shape" `Quick test_exact_json_shape;
          Alcotest.test_case "rejects a bare scalar" `Quick test_of_json_rejects_bare_scalar;
          Alcotest.test_case "rejects invalid base64" `Quick test_of_json_rejects_invalid_base64;
        ] );
    ]
