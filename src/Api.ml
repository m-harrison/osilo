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
  let requests          = Core.Std.List.map files ~f:(fun c -> (Auth.Token.token_of_string tok),(Printf.sprintf "%s/%s/%s" (Peer.host target) service c)) in
  let caps, not_covered = Auth.find_permissions s#get_capability_service requests in
  let caps'             = Coding.encode_capabilities caps in 
  `Assoc [
    ("files"       , (Coding.encode_file_list_message files));
    ("capabilities", caps');
  ] |> Yojson.Basic.to_string

let attach_required_capabilities_and_content target service paths contents s =
  let requests          = Core.Std.List.map paths ~f:(fun c -> Log.info (fun m -> m "Attaching W to %s" c); (Auth.Token.token_of_string "W"),(Printf.sprintf "%s/%s/%s" (Peer.host target) service c)) in
  let caps, not_covered = Auth.find_permissions s#get_capability_service requests in
  let caps'             = Coding.encode_capabilities caps in 
  `Assoc [
    ("contents"    , contents);
    ("capabilities", caps'   );
  ] |> Yojson.Basic.to_string

let read_from_cache peer service files s =
  Silo.read ~client:s#get_silo_client ~peer ~service ~paths:files
  >|= begin function 
      | `Assoc l -> Core.Std.List.partition_tf l ~f:(fun (n,j) -> not(j = `Null))
      | _        -> raise Malformed_data
      end 
  >|= fun (cached,not_cached) -> (cached, (Core.Std.List.map not_cached ~f:(fun (n,j) -> n)))

let write_to_cache peer service file_content requests s =
  let open Coding in
  let write_backs = Core.Std.List.filter requests ~f:(fun rf -> rf.write_back) in
  let files_to_write_back = 
    Core.Std.List.filter file_content 
      ~f:(fun (p,c) -> Core.Std.List.exists write_backs (fun rf -> Auth.vpath_subsumes_request rf.path p)) in
  Silo.write ~client:s#get_silo_client ~peer ~service ~contents:(`Assoc files_to_write_back)

let sign message s =
  Cstruct.of_string message
  |> Cryptography.Signing.sign ~key:s#get_private_key 
  |> Cstruct.to_string

let verify message sign peer s =
  Cryptography.Keying.lookup ~ks:(s#get_keying_service) ~peer:(Peer.create peer)
  >|= fun (ks,pub) ->
    s#set_keying_service ks;
    Cryptography.Signing.verify ~key:pub ~signature:(Cstruct.of_string sign) (Cstruct.of_string message)

let relog_paths_for_peer peer paths service s =
  s#set_peer_access_log (Core.Std.List.fold 
    ~init:s#get_peer_access_log paths
    ~f:(fun pal -> fun path -> Peer_access_log.log pal ~host:s#get_address ~peer ~service ~path))

let invalidate_paths_at_peer peer paths service s =
  let open Http_client in
  let body = Coding.encode_file_list_message paths |> Yojson.Basic.to_string in
  Http_client.post ~peer ~path:(Printf.sprintf "/peer/inv/%s/%s" (Peer.host s#get_address) service) ~body 
    ~auth:(Sig (Peer.host s#get_address, sign body s))

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

let authorise rd s =
  let headers = rd.Wm.Rd.req_headers in
  let secret  = s#get_secret_key |> Cryptography.Serialisation.serialise_cstruct in 
  Wm.continue
  (match Cohttp.Header.get_authorization headers with
  | Some (`Other key) -> if secret = key then `Authorized else `Basic "Wrong key"
  | _                 -> `Basic "No key")
  rd

let authorise_p2p rd s =
  let p = Wm.Rd.lookup_path_info "peer" rd in
  Cohttp_lwt_body.to_string rd.Wm.Rd.req_body
  >>= fun message -> 
    let headers = rd.Wm.Rd.req_headers in
    match Cohttp.Header.get_authorization headers with
    | Some (`Basic (src,sign)) -> 
      (if 
        (match p with
        | Some p' -> p' = src
        | None    -> true)
      then 
        verify message sign src s >>= 
          (begin function
           | true  -> Wm.continue `Authorized rd
           | false -> Wm.continue (`Basic "Signature not verifiable") rd
          end)
      else Wm.continue (`Basic "Wrong source peer") rd)
    | _ -> Wm.continue (`Basic "No authorisation provided") rd

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

    method is_authorized rd = authorise rd s

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
        Silo.read ~client:s#get_silo_client ~peer:s#get_address ~service:service' ~paths:files
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

    method is_authorized rd = authorise rd s

    method malformed_request rd =
      try 
        match Wm.Rd.lookup_path_info "peer" rd with
        | None       -> Wm.continue true rd
        | Some peer' -> let peer = Peer.create peer' in
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
              ~auth:(Sig (Peer.host s#get_address, sign body s))
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

    method is_authorized rd = authorise rd s

    method malformed_request rd =
      try 
        match Wm.Rd.lookup_path_info "peer" rd with
        | None       -> Wm.continue true rd
        | Some peer' -> let peer = Peer.create peer' in
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
              ~auth:(Sig (Peer.host s#get_address, sign body s))
            >>= fun (c,_) -> Wm.continue (c = 204) rd)
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

    method is_authorized rd = authorise rd s

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

    method is_authorized rd = authorise rd s    

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
          target <- Some (Peer.create peer');
          permission_list <- Coding.decode_permission_list_message message; 
          Wm.continue false rd)
      with 
      | Coding.Decoding_failed e -> 
          Wm.continue true rd
      | Malformed_data ->
          Wm.continue true rd

    method process_post rd =
      match target with
      | None -> Wm.continue false rd
      | Some target' ->
      match service with
      | None -> Wm.continue false rd
      | Some service' ->
      let capabilities = Auth.mint s#get_address s#get_secret_key service' permission_list in 
      let p_body       = Coding.encode_capabilities capabilities |> Yojson.Basic.to_string in
      let path         = 
        (Printf.sprintf "/peer/permit/%s/%s" 
        (s#get_address |> Peer.host) service') in
      Http_client.post ~peer:target' ~path ~body:p_body 
        ~auth:(Sig (Peer.host s#get_address, sign p_body s))
      >>= fun (c,b) ->
        Wm.continue true rd
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

    method is_authorized rd = authorise rd s

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
            (Silo.write ~client:s#get_silo_client ~peer:s#get_address ~service:service' ~contents
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

    method is_authorized rd = authorise rd s

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
            peer <- Some (Peer.create peer');
            file_content_to_set <- Coding.decode_file_content_list_message message;
            Wm.continue false rd)
      with
      | Coding.Decoding_failed e -> 
          Wm.continue true rd
      | Malformed_data ->
          Wm.continue true rd

    method process_post rd =
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
                  ~auth:(Sig (Peer.host s#get_address, sign body s))
                >>= fun (c,_) -> Wm.continue (c = 204) rd)
              else
                Wm.continue false rd
        | _ -> raise Malformed_data
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

    method is_authorized rd = authorise rd s

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
        Silo.delete ~client:s#get_silo_client ~peer:s#get_address ~service:service' ~paths:files
        >>= fun () -> 
          Wm.continue true rd
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

    val mutable files : string list = []

    method content_types_provided rd = 
      Wm.continue [("text/json", to_json)] rd

    method content_types_accepted rd = 
      Wm.continue [("text/json", validate_json)] rd

    method is_authorized rd = authorise_p2p rd s
  
    method allowed_methods rd = Wm.continue [`POST] rd 

    method malformed_request rd = 
      try match Wm.Rd.lookup_path_info "service" rd with
      | None          -> Wm.continue true rd
      | Some service' -> 
          (Cohttp_lwt_body.to_string rd.Wm.Rd.req_body)
          >>= (fun message -> 
            let files',capabilities = Coding.decode_file_and_capability_list_message message in
            let authorised_files = 
              Auth.authorise files' capabilities 
                (Auth.Token.token_of_string "R")
                s#get_secret_key s#get_address service' in
            (service <- Some service'); (files <- authorised_files); Wm.continue false rd)
      with
      | Coding.Decoding_failed s -> 
          (Log.debug (fun m -> m "Failed to decode message at /peer/get/:service: \n%s" s); 
          Wm.continue true rd)

    method process_post rd =
      try
        match service with 
        | None -> Wm.continue false rd
        | Some service' ->
            Silo.read ~client:s#get_silo_client ~peer:s#get_address ~service:service' ~paths:files
            >>= fun j ->
              (match j with 
              | `Assoc l  ->
                  s#set_peer_access_log 
                    (List.fold l ~init:s#get_peer_access_log
                    ~f:(fun log -> fun (f,_) -> 
                    Peer_access_log.log log ~host:s#get_address ~peer:(Peer.create "tmp") ~service:service' ~path:f));
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

    val mutable file_content : Yojson.Basic.json = `Null

    method content_types_provided rd = 
      Wm.continue [("text/json", to_json)] rd

    method content_types_accepted rd = 
      Wm.continue [("text/json", validate_json)] rd

    method is_authorized rd = authorise_p2p rd s
  
    method allowed_methods rd = Wm.continue [`POST] rd 

    method malformed_request rd = 
      try match Wm.Rd.lookup_path_info "service" rd with
      | None          -> Wm.continue true rd
      | Some service' -> 
          (Cohttp_lwt_body.to_string rd.Wm.Rd.req_body)
          >>= (fun message -> 
            let file_contents,capabilities = Coding.decode_file_content_and_capability_list_message message in
            let paths,contents = Core.Std.List.unzip file_contents in
            let authorised_files = 
              Auth.authorise paths capabilities 
                (Auth.Token.token_of_string "W")
                s#get_secret_key s#get_address service' in
            let authorised_file_content = 
              Core.Std.List.filter file_contents 
                ~f:(fun (p,c) -> Core.Std.List.fold ~init:false 
                  ~f:(fun acc -> fun auth -> acc || auth=p) authorised_files) in
            (service <- Some service'); (file_content <- `Assoc authorised_file_content); Wm.continue false rd)
      with
      | Coding.Decoding_failed s -> 
          (Log.debug (fun m -> m "Failed to decode message at /peer/get/:service: \n%s" s); 
          Wm.continue true rd)

    method process_post rd =
      try
        match service with 
        | None -> Wm.continue false rd
        | Some service' ->
            Silo.write ~client:s#get_silo_client ~peer:s#get_address ~service:service' ~contents:file_content
            >>= fun () -> Wm.continue true rd
      with
      | Malformed_data  -> Wm.continue false rd
  end

  class del s = object(self)
    inherit [Cohttp_lwt_body.t] Wm.resource

    val mutable service : string option = None

    val mutable files : string list = []

    val mutable source : Peer.t option = None

    method content_types_provided rd = 
      Wm.continue [("text/json", to_json)] rd

    method content_types_accepted rd = 
      Wm.continue [("text/json", validate_json)] rd

    method is_authorized rd = authorise_p2p rd s
  
    method allowed_methods rd = Wm.continue [`POST] rd 

    method malformed_request rd = 
      try match Wm.Rd.lookup_path_info "service" rd with
      | None          -> Wm.continue true rd
      | Some service' -> 
          (Cohttp_lwt_body.to_string rd.Wm.Rd.req_body)
          >>= (fun message -> 
            let files',capabilities = Coding.decode_file_and_capability_list_message message in
            let authorised_files = 
              Auth.authorise files' capabilities 
                (Auth.Token.token_of_string "D")
                s#get_secret_key s#get_address service' in
            (service <- Some service'); (files <- authorised_files); Wm.continue false rd)
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
            Silo.delete ~client:s#get_silo_client ~peer:s#get_address ~service:service' ~paths:files
            >>= fun () -> Wm.continue true rd
      with
      | Malformed_data  -> Wm.continue false rd
  end

  class inv s = object(self)
    inherit [Cohttp_lwt_body.t] Wm.resource

    val mutable peer : Peer.t option = None

    val mutable service : string option = None

    val mutable files : string list = []

    method content_types_provided rd = 
      Wm.continue [("text/json", to_json)] rd

    method content_types_accepted rd = 
      Wm.continue [("text/json", validate_json)] rd

    method is_authorized rd = authorise_p2p rd s
  
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
          let files' = Coding.decode_file_list_message message in
          peer <- Some (Peer.create peer_api);
          service <- Some service';
          files <- files';
          Wm.continue (peer_api = Peer.host s#get_address) rd)
      with
      | Coding.Decoding_failed e -> Wm.continue true rd

    method process_post rd =
      try
        match peer with
        | None          -> Wm.continue false rd
        | Some peer' -> 
        match service with
        | None          -> Wm.continue false rd
        | Some service' -> 
        Silo.delete ~client:s#get_silo_client ~peer:(peer') ~service:(service') ~paths:files
        >>= fun () ->
          Wm.continue true rd
      with 
      | _  -> Wm.continue false rd
  end

  class permit s = object(self)
    inherit [Cohttp_lwt_body.t] Wm.resource

    val mutable capabilities : Auth.M.t list = []

    method content_types_provided rd = 
      Wm.continue [("text/json", to_json)] rd

    method content_types_accepted rd = 
      Wm.continue [("text/json", validate_json)] rd

    method is_authorized rd = authorise_p2p rd s
  
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