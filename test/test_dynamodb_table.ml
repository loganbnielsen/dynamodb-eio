(* The negative-compile check ("passing one index's key to another index's
   functions is a type error") lives in negative_index_mismatch.ml.txt
   (named .txt so dune never compiles it — see its header for how to
   re-verify by hand). This file tests everything else: the positive path
   and Entity's discriminator check. *)

module User_primary = struct
  type pk = [ `Org of string ]
  type sk = [ `User of string ]

  let index_name = None
  let format_pk (`Org id) = "ORG#" ^ id
  let format_sk (`User id) = "USER#" ^ id
  let pk_attribute = "PK"
  let sk_attribute = "SK"
end

module User_by_email = struct
  type pk = [ `Email of string ]
  type sk = [ `Metadata ]

  let index_name = Some "gsi1"
  let format_pk (`Email e) = "EMAIL#" ^ e
  let format_sk `Metadata = "METADATA"
  let pk_attribute = "GSI1PK"
  let sk_attribute = "GSI1SK"
end

module Primary = Dynamodb_table.Index (User_primary)
module By_email = Dynamodb_table.Index (User_by_email)

(* Confirms the functor applies and produces distinct module shapes; the
   real type-level guarantee (mismatched pk is a compile error) can't be
   expressed as a runtime test — hence the separate negative-compile check. *)
let test_functor_instances_are_distinct () =
  Alcotest.(check string) "User_primary formats its own pk shape" "ORG#acme" (User_primary.format_pk (`Org "acme"));
  Alcotest.(check string) "User_by_email formats its own pk shape" "EMAIL#a@example.com"
    (User_by_email.format_pk (`Email "a@example.com"));
  (* Referencing both applications together proves they typecheck side by
     side with distinct pk/sk types — if types collapsed, this would fail
     to compile like the negative-compile check does. *)
  ignore (Primary.get, Primary.query_page, Primary.query_all, By_email.get, By_email.query_page, By_email.query_all)

module User_entity = Dynamodb_table.Entity (struct
  let name = "user"
end)

module Order_entity = Dynamodb_table.Entity (struct
  let name = "order"
end)

let test_entity_stamp_and_check_round_trip () =
  let item = [ ("id", Dynamodb_value.S "usr_1") ] in
  let stamped = User_entity.stamp item in
  match User_entity.check stamped with
  | Error e -> Alcotest.fail (Dynamodb_error.to_string e)
  | Ok item' -> Alcotest.(check bool) "stamped item still has the original field" true (item' = stamped)

let test_entity_check_rejects_wrong_entity () =
  let stamped_as_order = Order_entity.stamp [ ("id", Dynamodb_value.S "ord_1") ] in
  Alcotest.(check bool) "checking a User_entity against an Order-stamped item fails" true
    (match User_entity.check stamped_as_order with
     | Error (Wrong_entity { expected = "user"; got = Some "order" }) -> true
     | _ -> false)

let test_entity_check_rejects_missing_discriminator () =
  Alcotest.(check bool) "an item with no discriminator attribute at all fails" true
    (match User_entity.check [ ("id", Dynamodb_value.S "usr_1") ] with
     | Error (Wrong_entity { expected = "user"; got = None }) -> true
     | _ -> false)

let test_entity_stamp_replaces_existing_discriminator () =
  let item =
    [ (User_entity.discriminator_attribute, Dynamodb_value.S "order");
      ("id", Dynamodb_value.S "usr_1");
    ]
  in
  let stamped = User_entity.stamp item in
  Alcotest.(check int) "one discriminator" 1
    (List.length (List.filter (fun (k, _) -> k = User_entity.discriminator_attribute) stamped));
  Alcotest.(check bool) "now checks as user" true (Result.is_ok (User_entity.check stamped))

let () =
  Alcotest.run "dynamodb_table"
    [ ( "Index",
        [ Alcotest.test_case "functor instances are distinct, each formats its own key shape" `Quick
            test_functor_instances_are_distinct;
        ] );
      ( "Entity",
        [ Alcotest.test_case "stamp then check round trips" `Quick test_entity_stamp_and_check_round_trip;
          Alcotest.test_case "check rejects a different entity's stamped item" `Quick
            test_entity_check_rejects_wrong_entity;
          Alcotest.test_case "check rejects a missing discriminator" `Quick
            test_entity_check_rejects_missing_discriminator;
          Alcotest.test_case "stamp replaces existing discriminator" `Quick
            test_entity_stamp_replaces_existing_discriminator;
        ] );
    ]
