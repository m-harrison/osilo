open Core.Std
open Lwt.Infix
open Wm.Rd

exception Malformed_data
exception Path_info_exn of string

type provider_body = Cohttp_lwt_body.t Wm.provider
type acceptor_body = Cohttp_lwt_body.t Wm.acceptor
type 'a content_types = ((string * 'a) list, Cohttp_lwt_body.t) Wm.op

let src = Logs.Src.create ~doc:"logger for osilo API" "osilo.api"
module Log = (val Logs.src_log src : Logs.LOG)

let get_path_info_exn rd wildcard =
  match Wm.Rd.lookup_path_info wildcard rd with
  | Some p -> p
  | None   -> raise (Path_info_exn wildcard)

let attach_required_capabilities tok target service files s =
  let requests          = Core.Std.List.map files ~f:(fun c -> (Auth.Token.token_of_string tok),(Printf.sprintf "%s/%s/%s" (Peer.string_of_t target) service c)) in
  let caps, not_covered = Auth.find_permissions s#get_capability_service requests target service in
  let caps'             = Coding.encode_capabilities caps in
  `Assoc [
    ("files"       , (Coding.encode_file_list_message files));
    ("capabilities", caps');
  ] |> Yojson.Basic.to_string

let attach_required_capabilities_and_content target service paths contents s =
  let requests          = Core.Std.List.map paths ~f:(fun c -> Log.info (fun m -> m "Attaching W to %s" c); (Auth.Token.token_of_string "W"),(Printf.sprintf "%s/%s/%s" (Peer.string_of_t target) service c)) in
  let caps, not_covered = Auth.find_permissions s#get_capability_service requests target service in
  let caps'             = Coding.encode_capabilities caps in
  `Assoc [
    ("contents"    , contents);
    ("capabilities", caps'   );
  ] |> Yojson.Basic.to_string

let decrypt_read s file_content =
  match file_content with
  | `Assoc l ->
      `Assoc (List.map l ~f:(fun (f,c) ->
        match c with
        | `String message ->
            let ciphertext,nonce = Cryptography.Serialisation.deserialise_encrypted ~message   in
            let pl = Cryptography.decrypt ~key:s#get_secret_key ~ciphertext ~nonce  in
            f,(pl |> Cstruct.to_string |> Yojson.Basic.from_string)
        | `Null -> f,c
        | _     -> raise Malformed_data))
  | _ -> raise Malformed_data

let encrypt_write s file_content =
  match file_content with
  | `Assoc l ->
      `Assoc (List.map l ~f:(fun (f,c) ->
          let plaintext     = c |> Yojson.Basic.to_string |> Cstruct.of_string         in
          let ciphertext,nonce = Cryptography.encrypt ~key:s#get_secret_key ~plaintext in
          let e = Cryptography.Serialisation.serialise_encrypted ~ciphertext ~nonce    in
          f,`String e))
  | _ -> raise Malformed_data

let read_from_data_cache peer service files s =
  let hit,miss,cache = Core.Std.List.fold ~init:([],[],s#get_data_cache)
    ~f:(fun (h,m,dc) -> fun file ->
      match Data_cache.read ~peer:(Peer.string_of_t peer) ~service ~file dc with
      | None          -> h,file::m,dc
      | Some (j, dc') -> (file,j)::h,m,dc') files in
  s#set_data_cache cache; hit,miss

let write_to_data_cache peer service contents s =
  let cache = Core.Std.List.fold ~init:s#get_data_cache
      ~f:(fun dc -> fun (p,j) ->
          Data_cache.write ~peer:(Peer.string_of_t peer) ~service ~file:p ~content:j dc) contents
  in s#set_data_cache cache

let delete_from_data_cache peer service files s =
  let cache = Core.Std.List.fold ~init:s#get_data_cache
      ~f:(fun dc -> fun p ->
          Data_cache.invalidate ~peer:(Peer.string_of_t peer) ~service ~file:p dc) files
  in s#set_data_cache cache

let read_from_cache peer service files s =
  let hit,miss = read_from_data_cache peer service files s in
  Silo.read ~client:s#get_silo_client ~peer ~service ~paths:miss
  >|= (fun j -> decrypt_read s j)
  >|= begin function
      | `Assoc l -> Core.Std.List.partition_tf l ~f:(fun (n,j) -> not(j = `Null))
      | _        -> raise Malformed_data
      end
  >|= fun (cached,not_cached) ->
        write_to_data_cache peer service cached s;
        (hit @ cached, (Core.Std.List.map not_cached ~f:(fun (n,j) -> n)))

let write_to_cache peer service file_content requests s =
  let open Coding in
  let write_backs = Core.Std.List.filter requests ~f:(fun rf -> rf.write_back) in
  let files_to_write_back =
    Core.Std.List.filter file_content
      ~f:(fun (p,c) -> Core.Std.List.exists write_backs
             (fun rf -> Auth.vpath_subsumes_request rf.path p)) in
  write_to_data_cache peer service files_to_write_back s;
  Silo.write ~client:s#get_silo_client ~peer ~service ~contents:((`Assoc files_to_write_back) |> (encrypt_write s))

let delete_from_cache peer service paths s =
  delete_from_data_cache peer service paths s;
  Silo.delete ~client:s#get_silo_client ~peer ~service ~paths

let read_from_silo service paths s =
  let peer = s#get_address in
  let hit,miss = read_from_data_cache peer service paths s in
  Silo.read ~client:s#get_silo_client ~peer ~service ~paths:miss
  >|= (fun j ->
      let `Assoc pt = decrypt_read s j in
      write_to_data_cache peer service pt s; `Assoc (hit @ pt))

let write_to_silo service content s =
  let peer = s#get_address      in
  match content with
  | `Assoc c ->
      write_to_data_cache peer service c s;
      Silo.write ~client:s#get_silo_client ~peer ~service ~contents:(content |> (encrypt_write s))
  | _ -> assert false

let delete_from_silo service paths s =
  delete_from_cache s#get_address service paths s

let sign message s =
  Cstruct.of_string message
  |> Cryptography.Signing.sign ~key:s#get_private_key
  |> Cstruct.to_string

let rec verify message sign peer s is_retry =
  let open Cryptography in
  Keying.lookup ~ks:(s#get_keying_service) ~peer:(Peer.t_of_string peer)
  >>= fun (ks,pub) ->
    (s#set_keying_service ks;
     Signing.verify ~key:pub ~signature:(Cstruct.of_string sign) (Cstruct.of_string message))
    |> fun b -> if is_retry || b then Lwt.return b else
      (s#set_keying_service (Keying.invalidate ~ks ~peer:(Peer.t_of_string peer));
       verify message sign peer s true)

let relog_paths_for_peer peer paths service s =
  s#set_peer_access_log (Core.Std.List.fold
    ~init:s#get_peer_access_log paths
    ~f:(fun pal -> fun path -> Peer_access_log.log pal ~host:s#get_address ~peer ~service ~path))

let invalidate_paths_at_peer peer paths service s =
  let open Http_client in
  let body = Coding.encode_file_list_message paths |> Yojson.Basic.to_string in
  Http_client.post ~peer ~path:(Printf.sprintf "/peer/inv/%s/%s" (Peer.string_of_t s#get_address) service) ~body
    ~auth:(Sig (Peer.string_of_t s#get_address, sign body s))

let invalidate_paths_at_peers paths access_log service s =
  let path_peers,pal = Core.Std.List.fold ~init:([],s#get_peer_access_log) paths
    ~f:(fun (pp,pal') -> fun path ->
      let peers,pal'' = (Peer_access_log.delog pal' ~host:s#get_address ~service ~path)
      in (path,peers)::pp,pal'') in
  s#set_peer_access_log pal;
  let peers =
    path_peers
    |> Core.Std.List.fold ~init:[] ~f:(fun acc -> fun (_,ps) -> Core.Std.List.append acc ps)
    |> Core.Std.List.dedup ~compare:Peer.compare in
  let peer_paths = Core.Std.List.map peers
    ~f:(fun peer -> peer,
      (Core.Std.List.fold path_peers ~init:[] ~f:(fun acc -> fun (path,ps) ->
        Core.Std.List.append (if List.exists ps (fun p -> Peer.compare p peer = 0) then [path] else []) acc))) in
  Lwt_list.iter_s (fun (peer,paths) -> invalidate_paths_at_peer peer paths service s
    >|= fun (c,_) -> if c=204 then () else relog_paths_for_peer peer paths service s) peer_paths

class ping = object(self)
  inherit [Cohttp_lwt_body.t] Wm.resource

  method content_types_provided rd =
    Wm.continue [("text/plain", self#to_text)] rd

  method content_types_accepted rd = Wm.continue [] rd

  method allowed_methods rd = Wm.continue [`GET] rd

  method private to_text rd =
    let text = Log.debug (fun m -> m "Have been pinged."); "i am alive." in
    Wm.continue (`String (Printf.sprintf "%s" text)) rd
end

let authorise rd service s =
  let open Cryptography in
  let headers = rd.Wm.Rd.req_headers in
  let message =
    Printf.sprintf "%s/%s" (s#get_address |> Peer.string_of_t) service
    |> Cstruct.of_string in
  let key = s#get_public_key in
  Wm.continue
  (match Cohttp.Header.get_authorization headers with
    | Some (`Other api_key) ->
      if Signing.verify ~key
          ~signature:(api_key |> Serialisation.deserialise_cstruct) message
      then `Authorized else `Basic "Wrong key"
    | _ -> `Basic "No key")
  rd

let authorise_p2p rd message s =
  let p = Wm.Rd.lookup_path_info "peer" rd in
  let headers = rd.Wm.Rd.req_headers in
  match Cohttp.Header.get_authorization headers with
  | Some (`Basic (src,sign)) ->
    (if
      (match p with
      | Some p' -> p' = src
      | None    -> true)
    then
      verify message sign src s false >|=
        (begin function
         | true  -> Some src
         | false -> None
        end)
    else Lwt.return None)
  | _ -> Lwt.return None

let validate_json rd = (* checks can parse JSON *)
  try
    Cohttp_lwt_body.to_string rd.Wm.Rd.req_body
    >|= Yojson.Basic.from_string
    >>= fun _ -> Wm.continue true rd
  with
    _ -> Wm.continue false rd

let to_json rd =
  Cohttp_lwt_body.to_string rd.Wm.Rd.resp_body
  >>= fun s -> Wm.continue (`String s) rd

module Client = struct
  class get_local s = object(self)
    inherit [Cohttp_lwt_body.t] Wm.resource

    val mutable service : string option = None

    val mutable files : string list = []

    method content_types_provided rd =
      Wm.continue [("text/json", to_json)] rd

    method content_types_accepted rd =
      Wm.continue [("text/json", validate_json)] rd

    method allowed_methods rd = Wm.continue [`POST] rd

    method is_authorized rd =
      match service with
      | Some service' -> authorise rd service' s
      | None          -> assert false

    method malformed_request rd =
      try
        match Wm.Rd.lookup_path_info "service" rd with
        | None          -> Wm.continue true rd
        | Some service' ->
        Cohttp_lwt_body.to_string rd.Wm.Rd.req_body
        >>= (fun message ->
          let files' = Coding.decode_file_list_message message in
          service <- Some service';
          files <- files';
          Wm.continue false rd)
      with
      | Coding.Decoding_failed e -> Wm.continue true rd

    method process_post rd =
      try
        match service with
        | None          -> Wm.continue false rd
        | Some service' ->
        read_from_silo service' files s
        >|= begin function
            | `Assoc _ as j -> Yojson.Basic.to_string j
            | _ -> raise Malformed_data
            end
        >>= fun response ->
          Wm.continue true {rd with resp_body = (Cohttp_lwt_body.of_string response)}
      with
      | _  -> Wm.continue false rd
  end

  class get_remote s = object(self)
    inherit [Cohttp_lwt_body.t] Wm.resource

    val mutable target : Peer.t option = None

    val mutable service : string option = None

    val mutable plaintext : string option = None

    method content_types_provided rd =
      Wm.continue [("text/json", to_json)] rd

    method content_types_accepted rd =
      Wm.continue [("text/json", validate_json)] rd

    method allowed_methods rd = Wm.continue [`POST] rd

    method is_authorized rd =
      match service with
      | Some service' -> authorise rd service' s
      | None          -> assert false

    method malformed_request rd =
      try
        match Wm.Rd.lookup_path_info "peer" rd with
        | None       -> Wm.continue true rd
        | Some peer' -> let peer = Peer.t_of_string peer' in
        match Wm.Rd.lookup_path_info "service" rd with
        | None          -> Wm.continue true rd
        | Some service' ->
        Cohttp_lwt_body.to_string rd.Wm.Rd.req_body
        >>= (fun message ->
          target <- Some peer;
          service <- Some service';
          plaintext <- Some message;
          Wm.continue false rd)
      with
      | Coding.Decoding_failed e -> Wm.continue true rd

    method process_post rd =
      let open Coding in
      try
        match target with
        | None       -> Wm.continue false rd
        | Some peer' ->
        match service with
        | None          -> Wm.continue false rd
        | Some service' ->
        match plaintext with
        | None            -> Wm.continue false rd
        | Some plaintext' ->
        let requests = Coding.decode_remote_file_list_message plaintext' in
        let to_check,to_fetch = Core.Std.List.partition_tf requests ~f:(fun rf -> rf.check_cache) in
        read_from_cache peer' service' (Core.Std.List.map to_check ~f:(fun rf -> rf.path)) s (* Note, if a file is just `Null it is assumed to be not cached *)
        >>= fun (cached,to_fetch') ->
          (let to_fetch'' = List.append (Core.Std.List.map to_fetch ~f:(fun rf -> rf.path)) to_fetch' in
          if not(to_fetch'' = [])
          then
            (let body = attach_required_capabilities "R" peer' service' to_fetch'' s in
            let open Http_client in
            Http_client.post ~peer:peer' ~path:(Printf.sprintf "/peer/get/%s" service') ~body
              ~auth:(Sig (Peer.string_of_t s#get_address, sign body s))
            >>= (fun (c,b) ->
              let `Assoc fetched = Coding.decode_file_content_list_message b in
              let results = Core.Std.List.append fetched cached in
              let results' = (`Assoc results) |> Yojson.Basic.to_string in
              write_to_cache peer' service' fetched requests s
              >|= fun () -> results'))
          else
            Lwt.return ((`Assoc cached) |> Yojson.Basic.to_string))
        >>= fun response ->
          Wm.continue true {rd with resp_body = Cohttp_lwt_body.of_string response}
      with
      | _ -> Wm.continue false rd
  end

  class del_remote s = object(self)
    inherit [Cohttp_lwt_body.t] Wm.resource

    val mutable target : Peer.t option = None

    val mutable service : string option = None

    val mutable plaintext : string option = None

    method content_types_provided rd =
      Wm.continue [("text/json", to_json)] rd

    method content_types_accepted rd =
      Wm.continue [("text/json", validate_json)] rd

    method allowed_methods rd = Wm.continue [`POST] rd

    method is_authorized rd =
      match service with
      | Some service' -> authorise rd service' s
      | None          -> assert false

    method malformed_request rd =
      try
        match Wm.Rd.lookup_path_info "peer" rd with
        | None       -> Wm.continue true rd
        | Some peer' -> let peer = Peer.t_of_string peer' in
        match Wm.Rd.lookup_path_info "service" rd with
        | None          -> Wm.continue true rd
        | Some service' ->
        Cohttp_lwt_body.to_string rd.Wm.Rd.req_body
        >>= (fun message ->
          target <- Some peer;
          service <- Some service';
          plaintext <- Some message;
          Wm.continue false rd)
      with
      | Coding.Decoding_failed e -> Wm.continue true rd

    method process_post rd =
      let open Http_client in
      try
        match target with
        | None       -> Wm.continue false rd
        | Some peer' ->
        match service with
        | None          -> Wm.continue false rd
        | Some service' ->
        match plaintext with
        | None            -> Wm.continue false rd
        | Some plaintext' ->
        let requests = Coding.decode_file_list_message plaintext' in
        if not(requests = [])
          then
            (let body = attach_required_capabilities "D" peer' service' requests s in
            Http_client.post ~peer:peer' ~path:(Printf.sprintf "/peer/del/%s" service') ~body
              ~auth:(Sig (Peer.string_of_t s#get_address, sign body s))
            >>= fun (c,_) ->
            (if c = 204 then
               (delete_from_cache peer' service' requests s)
               >>= fun () -> Wm.continue true rd
            else Wm.continue false rd))
          else
            Wm.continue false rd
      with
      | _ -> Wm.continue false rd
  end

  class inv s = object(self)
    inherit [Cohttp_lwt_body.t] Wm.resource

    val mutable service : string option = None

    val mutable plaintext : string option = None

    method content_types_provided rd =
      Wm.continue [("text/json", to_json)] rd

    method content_types_accepted rd =
      Wm.continue [("text/json", validate_json)] rd

    method allowed_methods rd = Wm.continue [`POST] rd

    method is_authorized rd =
      match service with
      | Some service' -> authorise rd service' s
      | None          -> assert false

    method malformed_request rd =
      try
        match Wm.Rd.lookup_path_info "service" rd with
        | None          -> Wm.continue true rd
        | Some service' ->
        Cohttp_lwt_body.to_string rd.Wm.Rd.req_body
        >>= (fun message ->
          service <- Some service';
          plaintext <- Some message;
          Wm.continue false rd)
      with
      | Coding.Decoding_failed e -> Wm.continue true rd

    method process_post rd =
      try
        match service with
        | None          -> Wm.continue false rd
        | Some service' ->
        match plaintext with
        | None            -> Wm.continue false rd
        | Some plaintext' ->
        let paths = Coding.decode_file_list_message plaintext' in
        invalidate_paths_at_peers paths s#get_peer_access_log service' s
        >>= fun () -> Wm.continue true rd
      with
      | _ -> Wm.continue false rd
  end

  class permit s = object(self)
    inherit [Cohttp_lwt_body.t] Wm.resource

    val mutable service : string option = None

    val mutable target : Peer.t option = None

    val mutable permission_list : (Auth.Token.t * string) list = []

    method content_types_provided rd =
      Wm.continue [("text/json", to_json)] rd

    method content_types_accepted rd =
      Wm.continue [("text/json", validate_json)] rd

    method allowed_methods rd = Wm.continue [`POST] rd

    method is_authorized rd =
      match service with
      | Some service' -> authorise rd service' s
      | None          -> assert false

    method malformed_request rd =
      try
        match Wm.Rd.lookup_path_info "peer" rd with
        | None       -> Wm.continue true rd
        | Some peer' ->
        match Wm.Rd.lookup_path_info "service" rd with
        | None          -> Wm.continue true rd
        | Some service' ->
        Cohttp_lwt_body.to_string rd.Wm.Rd.req_body
        >>= (fun message ->
          service <- Some service';
          target <- Some (Peer.t_of_string peer');
          permission_list <- Coding.decode_permission_list_message message;
          Wm.continue false rd)
      with
      | Coding.Decoding_failed e ->
          Wm.continue true rd
      | Malformed_data ->
          Wm.continue true rd

    method process_post rd =
      let open Http_client in
      match target with
      | None -> Wm.continue false rd
      | Some target' ->
      match service with
      | None -> Wm.continue false rd
      | Some service' ->
      let capabilities = Auth.mint ~minter:s#get_address ~key:s#get_secret_key ~service:service' ~permissions:permission_list ~delegate:target' in
      let p_body       = Coding.encode_capabilities capabilities |> Yojson.Basic.to_string in
      let path         =
        (Printf.sprintf "/peer/permit/%s/%s"
        (s#get_address |> Peer.string_of_t) service') in
      Http_client.post ~peer:target' ~path ~body:p_body
        ~auth:(Sig (Peer.string_of_t s#get_address, sign p_body s))
      >>= fun (c,b) ->
        Wm.continue (c=204) rd
  end

  class set_local s = object(self)
    inherit [Cohttp_lwt_body.t] Wm.resource

    val mutable file_content_to_set : [`Assoc of (string * Yojson.Basic.json) list] = `Assoc []

    val mutable service : string option = None

    method content_types_provided rd =
      Wm.continue [("text/json", to_json)] rd

    method content_types_accepted rd =
      Wm.continue [("text/json", validate_json)] rd

    method allowed_methods rd = Wm.continue [`POST] rd

    method is_authorized rd =
      match service with
      | Some service' -> authorise rd service' s
      | None          -> assert false

    method malformed_request rd =
      try
        match Wm.Rd.lookup_path_info "service" rd with
        | None       -> Wm.continue true rd
        | Some service' ->
        Cohttp_lwt_body.to_string rd.Wm.Rd.req_body
        >>= (fun message ->
            service <- Some service';
            file_content_to_set <- Coding.decode_file_content_list_message message;
            Wm.continue false rd)
      with
      | Coding.Decoding_failed e ->
          Wm.continue true rd
      | Malformed_data ->
          Wm.continue true rd

    method process_post rd =
      try
        match service with
        | None -> raise Malformed_data
        | Some service' ->
        match file_content_to_set with
        | `Assoc j as contents ->
            (write_to_silo service' contents s
            >>= fun () -> Wm.continue true rd)
      with
      | Malformed_data -> Wm.continue false rd
  end

  class set_remote s = object(self)
    inherit [Cohttp_lwt_body.t] Wm.resource

    val mutable file_content_to_set : [`Assoc of (string * Yojson.Basic.json) list] = `Assoc []

    val mutable service : string option = None

    val mutable peer : Peer.t option = None

    method content_types_provided rd =
      Wm.continue [("text/json", to_json)] rd

    method content_types_accepted rd =
      Wm.continue [("text/json", validate_json)] rd

    method allowed_methods rd = Wm.continue [`POST] rd

    method is_authorized rd =
      match service with
      | Some service' -> authorise rd service' s
      | None          -> assert false

    method malformed_request rd =
      try
        match Wm.Rd.lookup_path_info "peer" rd with
        | None       -> Wm.continue true rd
        | Some peer' ->
        match Wm.Rd.lookup_path_info "service" rd with
        | None       -> Wm.continue true rd
        | Some service' ->
        Cohttp_lwt_body.to_string rd.Wm.Rd.req_body
        >>= (fun message ->
            service <- Some service';
            peer <- Some (Peer.t_of_string peer');
            file_content_to_set <- Coding.decode_file_content_list_message message;
            Wm.continue false rd)
      with
      | Coding.Decoding_failed e ->
          Wm.continue true rd
      | Malformed_data ->
          Wm.continue true rd

    method process_post rd =
      let open Http_client in
      let open Coding      in
      try
        match peer with
        | None -> raise Malformed_data
        | Some peer' ->
        match service with
        | None -> raise Malformed_data
        | Some service' ->
        match file_content_to_set with
        | `Assoc j as targets ->
            let paths,contents = Core.Std.List.unzip j in
            if not(paths = [])
              then
                (let body = attach_required_capabilities_and_content peer' service' paths targets s in
                Http_client.post ~peer:peer' ~path:(Printf.sprintf "/peer/set/%s" service') ~body
                  ~auth:(Sig (Peer.string_of_t s#get_address, sign body s)))
                >>= fun (c,_) -> (
                  if c = 204 then
                    (let requests = Core.Std.List.map paths
                        ~f:(fun p -> {path=p; check_cache=false; write_back=true;}) in
                    write_to_cache peer' service' j requests s
                    >>= fun () -> Wm.continue true rd)
                 else
                   Wm.continue false rd)
            else
              Wm.continue false rd
      with
      | Malformed_data -> Wm.continue false rd
  end

  class del_local s = object(self)
    inherit [Cohttp_lwt_body.t] Wm.resource

    val mutable service : string option = None

    val mutable files : string list = []

    method content_types_provided rd =
      Wm.continue [("text/json", to_json)] rd

    method content_types_accepted rd =
      Wm.continue [("text/json", validate_json)] rd

    method allowed_methods rd = Wm.continue [`POST] rd

    method is_authorized rd =
      match service with
      | Some service' -> authorise rd service' s
      | None          -> assert false

    method malformed_request rd =
      try
        match Wm.Rd.lookup_path_info "service" rd with
        | None          -> Wm.continue true rd
        | Some service' ->
        Cohttp_lwt_body.to_string rd.Wm.Rd.req_body
        >>= (fun message ->
          let files' = Coding.decode_file_list_message message in
          service <- Some service';
          files <- files';
          Wm.continue false rd)
      with
      | Coding.Decoding_failed e -> Wm.continue true rd

    method process_post rd =
      try
        match service with
        | None          -> Wm.continue false rd
        | Some service' ->
        delete_from_silo service' files s
        >>= fun () -> Wm.continue true rd
      with
      | _  -> Wm.continue false rd
  end
end

module Peer = struct
  class pub s = object(self)
    inherit [Cohttp_lwt_body.t] Wm.resource

    method content_types_provided rd = Wm.continue [("text/plain", self#to_text)] rd

    method content_types_accepted rd = Wm.continue [] rd

    method allowed_methods rd = Wm.continue [`GET] rd

    method private to_text rd =
      let pub = s#get_public_key in
      let str = Nocrypto.Rsa.sexp_of_pub pub |> Sexp.to_string in
      Wm.continue (`String str) rd
  end

  class get s = object(self)
    inherit [Cohttp_lwt_body.t] Wm.resource

    val mutable service : string option = None

    val mutable raw : string option = None

    val mutable source : Peer.t option = None

    method content_types_provided rd =
      Wm.continue [("text/json", to_json)] rd

    method content_types_accepted rd =
      Wm.continue [("text/json", validate_json)] rd

    method is_authorized rd =
      match raw with
      | Some message ->
          authorise_p2p rd message s
          >>= begin function
              | Some src -> source <- Some (Peer.t_of_string src); Wm.continue `Authorized rd
              | None     -> Wm.continue (`Basic "Not authorised") rd
              end
      | None -> Wm.continue (`Basic "No raw content to authorise") rd

    method allowed_methods rd = Wm.continue [`POST] rd

    method malformed_request rd =
      try match Wm.Rd.lookup_path_info "service" rd with
      | None          -> Wm.continue true rd
      | Some service' ->
        (Cohttp_lwt_body.to_string rd.Wm.Rd.req_body)
        >>= (fun message ->
          raw <- Some message;
          service <- Some service'; Wm.continue false rd)
      with
      | Coding.Decoding_failed s ->
          (Log.debug (fun m -> m "Failed to decode message at /peer/get/:service: \n%s" s);
          Wm.continue true rd)

    method process_post rd =
      try
        match service with
        | None -> Wm.continue false rd
        | Some service' ->
        match source with
        | None -> Wm.continue false rd
        | Some source' ->
        match raw with
        | None -> Wm.continue false rd
        | Some message ->
          let files',capabilities = Coding.decode_file_and_capability_list_message message in
          let authorised_files =
            Auth.authorise files' capabilities
            (Auth.Token.token_of_string "R")
            s#get_secret_key s#get_address service' source' in
            read_from_silo service' authorised_files s
            >>= fun j ->
              (match j with
              | `Assoc l  ->
                  s#set_peer_access_log
                    (List.fold l ~init:s#get_peer_access_log
                    ~f:(fun log -> fun (f,_) ->
                    Peer_access_log.log log ~host:s#get_address ~peer:source' ~service:service' ~path:f));
                  Lwt.return (Yojson.Basic.to_string j)
              | _ -> raise Malformed_data)
            >>= fun response ->
              Wm.continue true {rd with resp_body = Cohttp_lwt_body.of_string response}
      with
      | Malformed_data  -> Wm.continue false rd
  end

  class set s = object(self)
    inherit [Cohttp_lwt_body.t] Wm.resource

    val mutable service : string option = None

    val mutable raw : string option = None

    val mutable source : Peer.t option = None

    method content_types_provided rd =
      Wm.continue [("text/json", to_json)] rd

    method content_types_accepted rd =
      Wm.continue [("text/json", validate_json)] rd

    method is_authorized rd =
      match raw with
      | Some message ->
          authorise_p2p rd message s
          >>= begin function
              | Some src -> source <- Some (Peer.t_of_string src); Wm.continue `Authorized rd
              | None     -> Wm.continue (`Basic "Not authorised") rd
              end
      | None -> Wm.continue (`Basic "No raw content to authorise") rd

    method allowed_methods rd = Wm.continue [`POST] rd

    method malformed_request rd =
      try match Wm.Rd.lookup_path_info "service" rd with
      | None          -> Wm.continue true rd
      | Some service' ->
        (Cohttp_lwt_body.to_string rd.Wm.Rd.req_body)
        >>= (fun message ->
          raw <- Some message;
          service <- Some service'; Wm.continue false rd)
      with
      | Coding.Decoding_failed s ->
          (Log.debug (fun m -> m "Failed to decode message at /peer/get/:service: \n%s" s);
          Wm.continue true rd)

    method process_post rd =
      try
        match service with
        | None -> Wm.continue false rd
        | Some service' ->
        match source with
        | None -> Wm.continue false rd
        | Some source' ->
        match raw with
        | None -> Wm.continue false rd
        | Some message ->
          let file_contents,capabilities = Coding.decode_file_content_and_capability_list_message message in
          let paths,contents = Core.Std.List.unzip file_contents in
          let authorised_files =
            Auth.authorise paths capabilities
              (Auth.Token.token_of_string "W")
              s#get_secret_key s#get_address service' source' in
          let authorised_file_content =
            Core.Std.List.filter file_contents
              ~f:(fun (p,c) -> Core.Std.List.fold ~init:false
                ~f:(fun acc -> fun auth -> acc || auth=p) authorised_files) in
          write_to_silo service' (`Assoc authorised_file_content) s
            >>= fun () -> Wm.continue true rd
      with
      | Malformed_data  -> Wm.continue false rd
  end

  class del s = object(self)
    inherit [Cohttp_lwt_body.t] Wm.resource

    val mutable service : string option = None

    val mutable source : Peer.t option = None

    val mutable raw : string option = None

    method content_types_provided rd =
      Wm.continue [("text/json", to_json)] rd

    method content_types_accepted rd =
      Wm.continue [("text/json", validate_json)] rd

    method is_authorized rd =
      match raw with
      | Some message ->
          authorise_p2p rd message s
          >>= begin function
              | Some src -> source <- Some (Peer.t_of_string src); Wm.continue `Authorized rd
              | None     -> Wm.continue (`Basic "Not authorised") rd
              end
      | None -> Wm.continue (`Basic "No raw content to authorise") rd

    method allowed_methods rd = Wm.continue [`POST] rd

    method malformed_request rd =
      try match Wm.Rd.lookup_path_info "service" rd with
      | None          -> Wm.continue true rd
      | Some service' ->
          (Cohttp_lwt_body.to_string rd.Wm.Rd.req_body)
          >>= (fun message ->
            raw <- Some message;
            (service <- Some service'); Wm.continue false rd)
      with
      | Coding.Decoding_failed s ->
          (Log.debug (fun m -> m "Failed to decode message at /peer/get/:service: \n%s" s);
          Wm.continue true rd)

    method process_post rd =
      try
        match source with
        | None -> Wm.continue false rd
        | Some source' ->
        match service with
        | None -> Wm.continue false rd
        | Some service' ->
        match raw with
        | None -> Wm.continue false rd
        | Some message ->
          let files',capabilities = Coding.decode_file_and_capability_list_message message in
          let authorised_files =
            Auth.authorise files' capabilities
            (Auth.Token.token_of_string "D")
            s#get_secret_key s#get_address service' source' in
            delete_from_silo service' authorised_files s
            >>= fun () -> Wm.continue true rd
      with
      | Malformed_data  -> Wm.continue false rd
  end

  class inv s = object(self)
    inherit [Cohttp_lwt_body.t] Wm.resource

    val mutable service : string option = None

    val mutable files : string list = []

    val mutable raw : string option = None

    val mutable source : Peer.t option = None

    method content_types_provided rd =
      Wm.continue [("text/json", to_json)] rd

    method content_types_accepted rd =
      Wm.continue [("text/json", validate_json)] rd

    method is_authorized rd =
      match raw with
      | Some message ->
          authorise_p2p rd message s
          >>= begin function
              | Some src -> source <- Some (Peer.t_of_string src); Wm.continue `Authorized rd
              | None     -> Wm.continue (`Basic "Not authorised") rd
              end
      | None -> Wm.continue (`Basic "No raw content to authorise") rd

    method allowed_methods rd = Wm.continue [`POST] rd

    method malformed_request rd =
      try
        match Wm.Rd.lookup_path_info "peer" rd with
        | None          -> Wm.continue true rd
        | Some peer_api ->
        match Wm.Rd.lookup_path_info "service" rd with
        | None          -> Wm.continue true rd
        | Some service' ->
        Cohttp_lwt_body.to_string rd.Wm.Rd.req_body
        >>= (fun message ->
          raw <- Some message;
          let files' = Coding.decode_file_list_message message in
          service <- Some service';
          files <- files';
          Wm.continue (peer_api = Peer.string_of_t s#get_address) rd)
      with
      | Coding.Decoding_failed e -> Wm.continue true rd

    method process_post rd =
      try
        match source with
        | None      -> Wm.continue false rd
        | Some peer ->
        match service with
        | None          -> Wm.continue false rd
        | Some service' ->
        delete_from_cache peer service' files s
        >>= fun () -> Wm.continue true rd
      with
      | _  -> Wm.continue false rd
  end

  class permit s = object(self)
    inherit [Cohttp_lwt_body.t] Wm.resource

    val mutable capabilities : Auth.M.t list = []

    val mutable raw : string option = None

    val mutable source : Peer.t option = None

    method content_types_provided rd =
      Wm.continue [("text/json", to_json)] rd

    method content_types_accepted rd =
      Wm.continue [("text/json", validate_json)] rd

    method is_authorized rd =
      match raw with
      | Some message ->
          authorise_p2p rd message s
          >>= begin function
              | Some src -> source <- Some (Peer.t_of_string src); Wm.continue `Authorized rd
              | None     -> Wm.continue (`Basic "Not authorised") rd
              end
      | None -> Wm.continue (`Basic "No raw content to authorise") rd

    method allowed_methods rd = Wm.continue [`POST] rd

    method malformed_request rd =
      try
        match Wm.Rd.lookup_path_info "peer" rd with
        | None       -> Wm.continue true rd
        | Some peer' ->
        match Wm.Rd.lookup_path_info "service" rd with
        | None          -> Wm.continue true rd
        | Some service' ->
        Cohttp_lwt_body.to_string rd.Wm.Rd.req_body
        >>= (fun message ->
          raw <- Some message;
          let capabilities' =
            Coding.decode_capabilities
            (message |> Yojson.Basic.from_string)
          in (capabilities <- capabilities'; Wm.continue false rd))
      with
      | Coding.Decoding_failed e ->
          Log.debug (fun m -> m "Failed to decode message at /peer/permit/:peer/:service: \n%s" e);
          Wm.continue true rd

    method process_post rd =
      let cs = Auth.record_permissions s#get_capability_service capabilities
      in s#set_capability_service cs; Wm.continue true rd
  end
end
