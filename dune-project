(lang dune 3.0)
(name dynamodb-eio)
(version 0.1.0)
(generate_opam_files true)

(package
 (name dynamodb-eio)
 (synopsis "Eio-native DynamoDB client with a typed indexing layer, built on aws-eio")
 (description "\
A DynamoDB client on aws-eio (PutItem/GetItem/DeleteItem/UpdateItem/Query),
with paginated Query support, typed conditional writes (a small compare-and-swap surface:
create-iff-missing, version-stamp CAS) on PutItem/DeleteItem/UpdateItem, plus a
typed indexing layer: one module per index, each carrying its own nominally
distinct pk/sk types, generating its own typed get/query_page/query_all via a functor.
Passing one index's key to another index's functions is a type error, not a
runtime bug — the ElectroDB-replacement layer.")
 (maintainers "lbendtlynielsen@gmail.com")
 (authors "lbendtly")
 (license "MIT")
 (homepage "https://github.com/loganbnielsen/dynamodb-eio")
 (bug_reports "https://github.com/loganbnielsen/dynamodb-eio/issues")
 (source (github loganbnielsen/dynamodb-eio))
 (depends
  (ocaml (>= 5.4.0))
  (eio (>= 1.3))
  (aws-eio (>= 0.1.0))
  (yojson (>= 3.0.0))
  (base64 (>= 3.0.0))
  (eio_main (and (>= 1.3) :with-test))
  (alcotest :with-test)
  (odoc :with-doc)))
