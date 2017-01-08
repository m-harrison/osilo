open Core.Std
open Core_bench.Std

let peer = "localhost" |> Peer.create
let key = "fooBARfooBARfooBARfooBARfooBARfo" |> Coding.decode_cstruct
let service = "foo"

open Auth.Token

let number_paths = 20000
let paths = 
  Nocrypto_entropy_unix.initialize (); 
  List.init number_paths 
    ~f:(fun _ -> 
        Printf.sprintf "localhost/foo/a/%s" (Nocrypto.Rng.generate 32 
        |> Coding.encode_cstruct |> Core.Std.String.filter ~f:(fun c -> not(c='/'))) 
    )
let s = "R"
let t =  R

let bc_capability = Auth.mint peer key service [("R","a")]
let _,bc_capability' = List.unzip bc_capability
let cap = 
  match bc_capability' with 
  | c::_ -> c

let tokpaths =
  List.map paths ~f:(fun p -> (s,p))

let selection_args = 
  List.map paths ~f:(fun p -> (t,p))

let capabilities =
  Auth.mint peer key service tokpaths

let _,capabilities' = List.unzip capabilities

let tree = 
  List.fold ~init:Auth.CS.empty capabilities
    ~f:(fun s' -> fun (t',c') -> Auth.CS.record_if_most_general s' (t' |> token_of_string) c')

let tree' = Auth.CS.record_if_most_general (Auth.CS.empty) R cap

let () = Command.run (Bench.make_command [
  Bench.Test.create_indexed
    ~name:"Building CS tree"
    ~args:(List.range ~stride:250 ~start:`inclusive ~stop:`inclusive 1 number_paths)
    (fun num -> Staged.stage 
      (fun () -> ignore (List.fold ~init:Auth.CS.empty (List.take capabilities num)
        ~f:(fun s' -> fun (t',c') -> Auth.CS.record_if_most_general s' (t' |> token_of_string) c'))));
  Bench.Test.create_indexed
    ~name:"Verifying capabilities"
    ~args:(List.range ~stride:250 ~start:`inclusive ~stop:`inclusive 1 number_paths)
    (fun num -> Staged.stage 
      (fun () -> 
        ignore (List.map (List.take capabilities' num) ~f:(Auth.verify R (key |> Coding.encode_cstruct)))));
  Bench.Test.create_indexed
    ~name:"Best case capability selection"
    ~args:(List.range ~stride:250 ~start:`inclusive ~stop:`inclusive 1 number_paths)
    (fun num -> Staged.stage 
      (fun () -> ignore (Auth.find_permissions tree' (List.take selection_args num))));
  Bench.Test.create_indexed
    ~name:"Worst case capability selection"
    ~args:(List.range ~stride:250 ~start:`inclusive ~stop:`inclusive 1 number_paths)
    (fun num -> Staged.stage 
      (fun () -> ignore (Auth.find_permissions tree (List.take selection_args num))));
  Bench.Test.create_indexed
    ~name:"Best case capability verification"
    ~args:(List.range ~stride:250 ~start:`inclusive ~stop:`inclusive 1 number_paths)
    (fun num -> Staged.stage 
      (fun () -> ignore (Auth.authorise (List.take paths num) bc_capability' R key peer service)));
  Bench.Test.create_indexed
    ~name:"Worst case capability verification"
    ~args:(List.range ~stride:250 ~start:`inclusive ~stop:`inclusive 1 number_paths)
    (fun num -> Staged.stage 
      (fun () -> ignore (Auth.authorise (List.take paths num) (List.take capabilities' num) R key peer service)))
])