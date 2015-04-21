(**************************************************************************)
(*  Copyright 2014, Sebastien Mondet <seb@mondet.org>                     *)
(*                                                                        *)
(*  Licensed under the Apache License, Version 2.0 (the "License");       *)
(*  you may not use this file except in compliance with the License.      *)
(*  You may obtain a copy of the License at                               *)
(*                                                                        *)
(*      http://www.apache.org/licenses/LICENSE-2.0                        *)
(*                                                                        *)
(*  Unless required by applicable law or agreed to in writing, software   *)
(*  distributed under the License is distributed on an "AS IS" BASIS,     *)
(*  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or       *)
(*  implied.  See the License for the specific language governing         *)
(*  permissions and limitations under the License.                        *)
(**************************************************************************)

open Ketrew_pervasives
open Ketrew_unix_io

let default_persistent_state_key = "ketrew_persistent_state"

type plugin = [ `Compiled of string | `OCamlfind of string ]
              [@@deriving yojson]


type engine = {
  database_parameters: string;
  persistent_state_key: string [@default default_persistent_state_key];
  turn_unix_ssh_failure_into_target_failure: bool [@default false];
  host_timeout_upper_bound: float option [@default None];
} [@@deriving yojson]
type ui = {
  with_color: bool;
} [@@deriving yojson]
type server = {
  authorized_tokens_path: string option;
  listen_to: [ `Tls of (string * string * int) ];
  return_error_messages: bool;
  command_pipe: string option;
  daemon: bool;
  log_path: string option;
  server_engine: engine;
  server_ui: ui;
} [@@deriving yojson]
type client = {
  connection: string;
  token: string;
  client_ui [@key "ui"]: ui;
} [@@deriving yojson]
type standalone = {
  standalone_engine [@key "engine"]: engine;
  standalone_ui [@key "ui"]: ui;
} [@@deriving yojson]
type mode = [
  | `Standalone of standalone
  | `Client of client
  | `Server of server
] [@@deriving yojson]

type t = {
  debug_level: int;
  plugins: plugin list [@default []];
  mode: mode;
} [@@deriving yojson]

let log t =
  let open Log in
  let item name l = s name % s ": " % l % n in
  let sublist l = n % indent (separate empty l) in
  let common =
    sublist [
      item "Debug-level" (i t.debug_level);
      item "Plugins" (match t.plugins with
        | [] -> s "None"
        | more -> sublist (List.map more ~f:(function
          | `Compiled path -> item "Compiled"  (quote path)
          | `OCamlfind pack -> item "OCamlfind package" (quote pack))))
    ] in
  let ui t =
    item "Colors"
      (s (if t.with_color then "with" else "without") % s " colors")
  in
  let engine t =
    sublist [
      item "Database" (quote t.database_parameters);
      item "State-key" (quote t.persistent_state_key);
      item "Unix-failure"
        ((if t.turn_unix_ssh_failure_into_target_failure
          then s "turns"
          else s "does not turn") % s " into target failure");
    ] in
  match t.mode with
  | `Standalone {standalone_engine; standalone_ui} ->
    item "Mode" (s "Standalone")
    % item "Engine" (engine standalone_engine)
    % item "UI" (ui standalone_ui)
    % item "Misc" common
  | `Client client ->
    item "Mode" (s "Client")
    % item "Connection" (quote client.connection)
    % item "Auth-token" (quote client.token)
    % item "UI" (ui client.client_ui)
    % item "Misc" common
  | `Server srv ->
    item "Mode" (s "Server")
    % item "Engine" (engine srv.server_engine)
    % item "UI" (ui srv.server_ui)
    % item "HTTP-server" (sublist [
        item "Authorized tokens"
          OCaml.(option string srv.authorized_tokens_path);
        item "Daemonize" (OCaml.bool srv.daemon);
        item "Command Pipe" (OCaml.option quote srv.command_pipe);
        item "Log-path" (OCaml.option quote srv.log_path);
        item "Return-error-messages" (OCaml.bool srv.return_error_messages);
        item "Listen"
          (let `Tls (cert, key, port) = srv.listen_to in
           sublist [
             item "Port" (i port);
             item "Certificate" (quote cert);
             item "Key" (quote key);
           ])
      ])
    % item "Misc" common


let default_database_path =
  Sys.getenv "HOME" ^ "/.ketrew/database"

let create ?(debug_level=0) ?(plugins=[]) mode =
  {debug_level; plugins; mode;}


let ui ?(with_color=true) () = {with_color}
let default_ui = ui ()

let engine
    ?(database_parameters=default_database_path)
    ?(persistent_state_key=default_persistent_state_key)
    ?(turn_unix_ssh_failure_into_target_failure=false)
    ?host_timeout_upper_bound () = {
  database_parameters;
  persistent_state_key;
  turn_unix_ssh_failure_into_target_failure;
  host_timeout_upper_bound;
}
let default_engine = engine ()

let standalone ?(ui=default_ui) ?engine () =
  let standalone_engine = Option.value engine ~default:default_engine in
  (`Standalone {standalone_engine; standalone_ui = ui})

let client ?(ui=default_ui) ~token connection =
  (`Client {client_ui = ui; connection; token})

let server
    ?ui ?engine
    ?authorized_tokens_path ?(return_error_messages=false)
    ?command_pipe ?(daemon=false) ?log_path listen_to =
  let server_engine = Option.value engine ~default:default_engine in
  let server_ui = Option.value ui ~default:default_ui in
  (`Server {server_engine; authorized_tokens_path; listen_to; server_ui;
            return_error_messages; command_pipe; daemon; log_path; })


let plugins t = t.plugins

let server_configuration t =
  match t.mode with
  | `Server s -> Some s
  | other -> None
let listen_to s = s.listen_to
let return_error_messages s = s.return_error_messages
let authorized_tokens_path s = s.authorized_tokens_path
let command_pipe s = s.command_pipe
let daemon       s = s.daemon
let log_path     s = s.log_path
let database_parameters e = e.database_parameters
let persistent_state_key e = e.persistent_state_key
let is_unix_ssh_failure_fatal e = e.turn_unix_ssh_failure_into_target_failure
let mode t = t.mode
let standalone_engine st = st.standalone_engine
let server_engine s = s.server_engine
let connection c = c.connection
let token c = c.token

let standalone_of_server s =
  {standalone_ui = s.server_ui;
   standalone_engine = s.server_engine;}

module File = struct
  type configuration = t
   [@@deriving yojson]
  type profile = {
    name: string;
    configuration: configuration;
  } [@@deriving yojson]
  type t = [
    | `Ketrew_configuration [@name "Ketrew"] of profile list
  ] [@@deriving yojson]

  let parse_string_exn s =
    match Yojson.Safe.from_string s |> of_yojson with
    | `Ok o -> o
    | `Error e -> failwith (fmt "Configuration parsing error: %s" e)

  let to_string s = to_yojson s |> Yojson.Safe.pretty_to_string ~std:true

  let get_profile t the_name =
    match t with
    | `Ketrew_configuration profiles ->
      List.find_map profiles ~f:(fun {name; configuration} ->
          if name = the_name then Some configuration else None)

  let pick_profile_exn ?name t =
    let name =
      match name with
      | Some n -> n
      | None ->
        try Sys.getenv "KETREW_PROFILE" with
        | _ -> "default"
    in
    get_profile t name
    |> Option.value_exn ~msg:(fmt "profile %S not found" name)

  let default_ketrew_path =
    Sys.getenv "HOME" ^ "/.ketrew/"

  let default_configuration_filenames = [
    "configuration.json";
    "configuration.ml";
    "configuration.sh";
    "configuration.url";
  ]

  let get_path ?root () =
    let env n () = try Some (Sys.getenv n) with | _ -> None in
    let exists path () = if Sys.file_exists path then Some path else None in
    let try_options l last_resort =
      match List.find_map l ~f:(fun f -> f ()) with
      | Some s -> s
      | None -> last_resort in
    let possible_files = [
        env "KETREW_CONFIGURATION";
        env "KETREW_CONFIG";
      ] @ List.map (exists) default_configuration_filenames in
    let ketrew_path =
      try_options [
        (fun () -> root);
        env "KETREW_ROOT";
      ] default_ketrew_path in
    try_options possible_files (ketrew_path ^ "configuration.json")

  let read_file_no_lwt path =
    let i = open_in path in
    begin try
      let content =
        let buf = Buffer.create 1023 in
        let rec get_all () =
          begin try
            let line = input_line i in
            Buffer.add_string buf (line ^ "\n");
            get_all ()
          with e -> ()
          end;
        in
        get_all ();
        Buffer.contents buf in
      close_in i;
      content
    with e -> close_in i; raise e
    end

  let read_command_output_no_lwt_exn cmd =
    let ic = Unix.open_process_in cmd in
    let buf = Buffer.create 24 in
    begin try
      while true do
        Buffer.add_char buf (input_char ic)
      done
    with End_of_file -> ()
    end;
    begin match Unix.close_process_in ic with
    | Unix.WEXITED 0 -> Buffer.contents buf
    | _ -> failwith (fmt "failed command: %S" cmd)
    end


  let load_exn path =
    let ext = try Filename.chop_extension path with Invalid_argument _ -> "" in
    begin match ext with
    | "json" ->
        read_file_no_lwt path
    | "ml"   ->
        read_command_output_no_lwt_exn
          (fmt "ocaml %s" Filename.(quote path))
    | "sh"   ->
        read_command_output_no_lwt_exn path
    | "url"  ->
        failwith "Getting config from URL: not implemented"
    | other  ->
         Log.(s "Config file should a discriminatory extension, not "
            % quote other % s " pretending it is `.json`" @ warning);
        read_file_no_lwt path
    end
    |> parse_string_exn

end


let apply_globals t =
  global_debug_level := t.debug_level;
  let color, host_timeout =
    match t.mode with
    | `Client {client_ui; connection} -> (client_ui.with_color, None)
    | `Standalone {standalone_ui; standalone_engine} ->
      (standalone_ui.with_color, standalone_engine.host_timeout_upper_bound)
    | `Server {server_engine; server_ui; _} ->
      (server_ui.with_color, server_engine.host_timeout_upper_bound)
  in
  global_with_color := color;
  Log.(s "Configuration: setting globals: "
       % indent (n
         % s "debug_level: " % i !global_debug_level % n
         % s "with_color: " % OCaml.bool !global_with_color % n
         % s "timeout upper bound: " % OCaml.(option float host_timeout)
       ) @ very_verbose);
  begin match host_timeout with
  | Some ht -> Ketrew_host_io.default_timeout_upper_bound := ht
  | None -> ()
  end

let load_exn ?(and_apply=true) ?profile how =
  let conf =
    match how with
    | `Override c -> c
    | `From_path path ->
      File.(load_exn path |> pick_profile_exn ?name:profile)
    | `In_directory root ->
      File.(get_path ~root () |> load_exn |> pick_profile_exn ?name:profile)
    | `Guess ->
      File.(get_path () |> load_exn |> pick_profile_exn ?name:profile)
  in
  if and_apply then (
    apply_globals conf;
    Ketrew_plugin.load_plugins_no_lwt_exn conf.plugins
  );
  conf


type profile = File.profile

let profile name configuration =
  File.({name; configuration})

let output l =
  File.(`Ketrew_configuration l |> to_string |> print_string)

let to_json l =
  File.(`Ketrew_configuration l |> to_string)
