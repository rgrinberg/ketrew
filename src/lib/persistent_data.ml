(**************************************************************************)
(*    Copyright 2014, 2015:                                               *)
(*          Sebastien Mondet <seb@mondet.org>,                            *)
(*          Leonid Rozenberg <leonidr@gmail.com>,                         *)
(*          Arun Ahuja <aahuja11@gmail.com>,                              *)
(*          Jeff Hammerbacher <jeff.hammerbacher@gmail.com>               *)
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
(** 
   
   This module is the one and only interface to the PostgreSQL
   database managed by Ketrew.

   - {!SQL}: Generic, pure OCaml, “Better-Typed” construction API.
   - {!DB}: Higher-lever wrapping of the `ocaml-postgresql` API.
   - {!Schema}: Description of Ketrew's particular schema using th {!SQL} module.
   - {!Event_source}: API to use Lwt/React to wait for interesting
     events from this layer.
   - {!Change}: Ketrew's actual interesting events (uses {!Event_source}).
   - {!Error}: Usual error module.
   - [type t] and the main Ketrew-specific operations

*)

open Ketrew_pure
open Internal_pervasives
open Unix_io

include Logging.Global.Make_module_error_and_info(struct
    let module_name = "Persistence"
  end)
open Logging.Global


let debug = ref false

let dbg fmt =
  let open Printf in
  ksprintf (eprintf "Persistend_data: %s\n%!") fmt


(** Experiment with Typed-SQL queries using GADTs all over the place. *)
module SQL = struct

  type untyped_sql_field =
    [ `Blob of string | `Null ]
  [@@deriving show]

  (** Ugly/imperative implementation of a parameter counter.

      The idea is to keep all arguments in a list and return $1, $2,
      $3, … while building the query string; then we can render the
      arguments into an [untyped_sql_field array] which respects the
      order.
  *)
  module Positional_parameter = struct
    type t = {
      mutable rev_args: untyped_sql_field list;
    }

    let create () = {rev_args = []}
    let next t arg =
      t.rev_args <- arg :: t.rev_args; 
      let c = List.length t.rev_args in
      fmt "$%d" c

    let render t =
      Array.of_list (List.rev t.rev_args)
  end

  type query = {
    query: string [@main ];
    arguments: untyped_sql_field array;
  } [@@deriving make, show]

  let query s pos =
    make_query s ~arguments:(Positional_parameter.render pos)


  (** High-level types of the query-building EDSL. *)
  module Type = struct

    module type STRINGABLE = sig
      type t
      val to_string : t -> string
      val of_string : string -> t option
    end

    type _ t =
      | Byte_array : string t
      | Stringable: (module STRINGABLE with type t = 'a) -> 'a t

    let to_sql: type a. a t -> string =
      function
      | Byte_array -> "BYTEA NOT NULL"
      | Stringable _ ->  "BYTEA NOT NULL"
  end


  (** Fields are types and names; they end up in ["CREATE TABLE"],
      ["SELECT"], ["WHERE"], etc. constructs. *)
  module Field = struct
    type ('a, 'b) t = {
      name: string;
      sql_type: 'a Type.t;
      tag: 'b;
    }

    (** A [Field.List.t] is an heterogeneous list that works like a
        Printf/Scanf format type.

        See also {{:https://drup.github.io/2016/08/02/difflists/}}. *)
    module List = struct

      type ('a, 'b) field = ('a, 'b) t

      type (_, _) t =
        | [] : ('a, 'a) t
        | ( :: ) : ('c, 'd) field * ('a, 'b) t -> (('c * 'd) -> 'a, 'b) t

      let rec to_sql_name_type:
        type a b. (a, b) t -> (string * string) list =
          function
          | [] -> []
          | { name; sql_type; tag } :: more ->
            (name, Type.to_sql sql_type) :: (to_sql_name_type more)

      let to_sql_create l =
        fmt "(%s)" (to_sql_name_type l
                    |> List.map ~f:(fun (n, t) -> fmt "%s %s" n t)
                    |> String.concat ~sep:", ")

      let to_sql_select l =
        fmt "%s" (to_sql_name_type l
                    |> List.map ~f:(fun (n, t) -> n)
                    |> String.concat ~sep:", ")

      let to_sql_insert l =
        fmt "(%s)" (to_sql_name_type l
                    |> List.map ~f:(fun (n, t) -> n)
                    |> String.concat ~sep:", ")

      (** The equivalent of [Printf.scanf] for field-lists. *)
      let parse_sql_fields_exn
          fields (untyped : untyped_sql_field list) on_success =
        let rec loop
          : type a b.
            a -> untyped_sql_field list -> (a, b) t -> b =
          fun f unty fds ->
            match fds, unty with
            | [], [] ->
              f
            | [], _ ->
              Printf.ksprintf failwith "Too many columns: %d"
                (List.length untyped)
            | _ :: _, [] ->
              Printf.ksprintf failwith "Not enough columns: %d"
                (List.length untyped)
            | { name; sql_type = Type.Byte_array; tag } :: more,
              untyfield :: rest ->
              begin match untyfield with
              | `Null ->
                Printf.ksprintf failwith "%s is Null while expecting blob" name
              |`Blob b ->
                loop (f (b, tag)) rest more
              end
            | { name; sql_type = Type.Stringable m; tag } :: more,
              untyfield :: rest ->
              begin match untyfield with
              | `Null ->
                Printf.ksprintf failwith "%s is Null while expecting blob" name
              |`Blob b ->
                let module M = (val m) in
                begin match M.of_string b with
                | None ->
                  Printf.ksprintf failwith
                    "%s is %S while expecting enumeration" name b
                | Some v ->
                    loop (f (v, tag)) rest more
                end
              end
        in
        loop on_success untyped fields

      (** The equivalent of [Printf.kprintf] for field-lists. *)
      let rec kunparse_to_sql
        : type ty v. ((string * untyped_sql_field) list -> v) -> (ty, v) t -> ty
        = fun k -> function
        | [] -> k []
        | {name; sql_type = Type.Byte_array; _} :: more ->
          let f (s, _) =
            kunparse_to_sql (fun l -> k ((name, `Blob s) :: l)) more
          in
          f
        | {name; sql_type = Type.Stringable m; _} :: more ->
          let f (s, _) =
            let module M = (val m) in
            let converted = M.to_string s in
            kunparse_to_sql (fun l -> k ((name, `Blob converted) :: l)) more
          in
          f

    end

    let make tag name sql_type = {name; sql_type; tag}

    let byte_array tag name = make tag name Type.Byte_array

    let stringable tag name m = make tag name Type.(Stringable m) 

    let ex_s = make `S "string" Type.Byte_array
    let ex_t = byte_array `T "t"
    let ex_u = byte_array `U "u"

    let to_sql_set pos l =
      let f (name, untyped_sql_field) =
        fmt "%s = %s"
          name
          (Positional_parameter.next pos untyped_sql_field)
      in
      Nonstd.List.map ~f l |> String.concat ~sep:", "

    let to_sql_values pos l =
      let f (name, untyped_sql_field) =
        fmt "%s" (Positional_parameter.next pos untyped_sql_field) in
      Nonstd.List.map ~f l |> String.concat ~sep:", " |> fmt "(%s)"

    let ex_set =
      let pos = Positional_parameter.create () in
      List.(kunparse_to_sql
              (to_sql_set pos)
              [ex_s; ex_t])
        ("SEtting S", `S) ("Seetttting T", `T)
  end

  (** A SQL table is a named reccord (i.e. [Field.List.t]). *)
  module Table = struct

    type ('a, 'b) t = {
      fields: ('a, 'b) Field.List.t;
      name: string;
    }
    let make name fields = {name; fields}

    let to_sql_create {name; fields} =
      fmt "CREATE TABLE IF NOT EXISTS %s %s"
        name (Field.List.to_sql_create fields)
      |> make_query ~arguments:[| |]

    let ex1 () =
      make "test" Field.(List.[ex_s; ex_t; ex_u])


  end

  (** {!Logic} is how we construct ["WHERE"] clauses.  *)
  module Logic = struct

    type t =
      (* | Equal_string: (string, _) Field.t * string -> t *)
      | Equal: ('a, _) Field.t * 'a -> t
      | Bin_op: [ `And | `Or ] * t * t -> t

    module Infix = struct
      let (===) a b = Equal (a, b) 
      let (&&&) a b = Bin_op (`And, a, b)
      let (|||) a b = Bin_op (`Or, a, b)
    end

    let ex1 () =
      let open Infix in
      (Field.ex_s === "some string")
      &&& 
      (Field.ex_u === "some other string")
      

    let rec to_sql_where pos =
      function
      | Equal ({Field. name; sql_type = Type.Byte_array; tag }, v) ->
        let arg = Positional_parameter.next pos (`Blob v) in
        fmt "%s = %s" name arg
      | Equal ({Field. name; sql_type = Type.Stringable m; tag }, v) ->
        let arg =
          let module M = (val m) in
          let blob = M.to_string v in
          Positional_parameter.next pos (`Blob blob) in
        fmt "%s = %s" name arg
      | Bin_op (op, a, b) ->
        fmt "(%s %s %s)"
          (to_sql_where pos a)
          (match op with `And -> "AND" | `Or -> "OR")
          (to_sql_where pos b)

  end

  let select fields ~from ?where f =
    let pos = Positional_parameter.create () in
    let qst =
      fmt "SELECT %s FROM %s %s"
        (Field.List.to_sql_select fields)
        from.Table.name
        (match where with
        | Some w -> "WHERE " ^ Logic.to_sql_where pos w
        | None -> "")
    in
    let result_parser untyped =
      Field.List.parse_sql_fields_exn fields untyped f
    in
    let q = query qst pos in
    (* dbg "select qst: %s" qst; *)
    q, result_parser

  let update ~table ~where set =
    let pos = Positional_parameter.create () in
    Field.List.kunparse_to_sql (fun sets ->
        let q =
          fmt "UPDATE %s SET %s WHERE %s"
            table.Table.name
            (Field.to_sql_set pos sets)
            (Logic.to_sql_where pos where)
        in
        query q pos
      ) set

  let insert into =
    let pos = Positional_parameter.create () in
    Field.List.kunparse_to_sql (fun sets ->
        let q =
          fmt "INSERT INTO %s %s VALUES %s"
            into.Table.name
            (Field.List.to_sql_insert into.Table.fields)
            (Field.to_sql_values pos sets)
        in
        query q pos
      ) into.Table.fields

  let delete ?where ~from () =
    let pos = Positional_parameter.create () in
    let q =
      fmt "DELETE FROM %s %s" 
        from.Table.name
        (Option.value_map ~default:"" where ~f:(fun w ->
             "WHERE " ^ Logic.to_sql_where pos w))
    in
    query q pos


  let ex_select () =
    select
      Field.List.[Field.ex_s]
      ~from:(Table.ex1 ()) ~where:(Logic.ex1 ())
      (fun (bs, `S) ->
         dbg "%s" bs)


end

(** Wrapping of the {!Postgresql} module:

    - Inside {!Lwt_preemptive.detach} threads.
    - With a mutex protecting the write accesses (function {!in_transaction}).

 *)
module DB = struct
  open Printf

  module PG = Postgresql

  type t = {
    handle: PG.connection;
    action_mutex: Lwt_mutex.t;
  }


  let in_posix_thread ~on_exn f =
    Lwt_preemptive.detach begin fun () ->
      try `Ok (f ())
      with e -> `Error (on_exn e)
    end ()

  let exn_to_string =
    function
    | PG.Error e -> sprintf "Postgres-Error: %s" (PG.string_of_error e)
    | e -> (Printexc.to_string e)

  let exn_error loc exn =`Database (loc, `Exn (exn_to_string exn))

  let in_posix_thread_or_error ~loc f =
    in_posix_thread f ~on_exn:(exn_error loc)

  let dbg_handle handle fmt =
    let open Printf in
    ksprintf (fun s ->
        eprintf "Handle-postgresql: %s\n" s;
        eprintf "  db      = %s\n" handle#db;
        eprintf "  user    = %s\n" handle#user;
        eprintf "  pass    = %s\n" handle#pass;
        eprintf "  host    = %s\n" handle#host;
        eprintf "  port    = %s\n" handle#port;
        eprintf "  tty     = %s\n" handle#tty;
        eprintf "  option  = %s\n" handle#options;
        eprintf "  pid     = %i\n" handle#backend_pid
      ) fmt

  let create conninfo =
    let action_mutex = Lwt_mutex.create () in
    in_posix_thread_or_error (`Load conninfo) begin fun () ->
      {handle = new PG.connection ~conninfo ();
       action_mutex}
    end

  let db_fail ?query ?(arguments = [| |]) fmt =
    ksprintf
      (fun s ->
         ksprintf failwith "%s (QUERY: %s, ARGS: [%s])" s
           (Option.value query ~default:"NONE")
           (Array.to_list arguments
            |> List.map ~f:(function
              | `Blob b -> b
              | `Null -> "NULL")
            |> String.concat ~sep:", ")
      ) fmt

  let exec_sql_exn (t : t) ~query ~arguments =
    let show_res query args res =
      dbg "\n  %s\n  args: [%s]\n  status: %s | error: %s | tuples: %d × %d"
        query
        (Array.map args ~f:(function
           | `Null -> "NULL"
           | `Blob b -> sprintf "%S" b)
         |> Array.to_list
         |> String.concat ~sep:", ")
        (PG.result_status res#status) res#error res#ntuples res#nfields;
      for i = 0 to res#ntuples - 1 do
        dbg "     (%s)"
          (List.init res#nfields (fun j ->
               if res#getisnull i j then "Null"
               else sprintf "%S" (PG.unescape_bytea (res#getvalue i j)))
           |> String.concat ~sep:", ");
      done;
    in
    let res =
      let params =
        Array.map arguments ~f:(function | `Null -> PG.null | `Blob s -> s) in
      let binary_params =
        Array.map arguments ~f:(function `Null -> false | `Blob _ -> true) in
      t.handle#exec query ~params ~binary_params
    in
    (if !debug then show_res query arguments res);
    begin match res#status with
    | PG.Command_ok -> `Unit
    | PG.Tuples_ok ->
      `Tuples
        (List.init res#ntuples (fun i ->
             (List.init res#nfields (fun j ->
                  if res#getisnull i j then `Null
                  else `Blob (PG.unescape_bytea (res#getvalue i j))))))
    | PG.Empty_query
    | PG.Copy_out
    | PG.Copy_in
    | PG.Bad_response
    | PG.Nonfatal_error
    | PG.Fatal_error
    | PG.Copy_both
    | PG.Single_tuple  ->
      db_fail "SQL Query failed: status: %s, error: %s"
          ~query ~arguments
         (PG.result_status res#status) res#error
    end

  let exec_unit ?(arguments=[| |]) (t : t) ~query =
    in_posix_thread_or_error ~loc:(`Exec (query, arguments)) begin fun () ->
      begin match exec_sql_exn t ~query ~arguments with
      | `Unit -> ()
      | `Tuples other ->
        db_fail "Unexpected return from unit-query: length: %d"
          ~query ~arguments
          (List.length other)
      end
    end

  let exec_one ?(arguments=[| |]) (t : t) ~query =
    in_posix_thread_or_error ~loc:(`Exec (query, arguments)) begin fun () ->
      begin match exec_sql_exn t ~query ~arguments with
      | `Unit ->
        db_fail "Unexpected return from single-result-query: Unit"
          ~query ~arguments
      | `Tuples [one] -> one
      | `Tuples other ->
        db_fail "Unexpected return from single-result query: length: %d"
          ~query ~arguments
          (List.length other)
      end
    end

  let exec_multi ?(arguments=[| |]) (t : t) ~query =
    in_posix_thread_or_error ~loc:(`Exec (query, arguments)) begin fun () ->
      begin match exec_sql_exn t ~query ~arguments with
      | `Unit ->
        db_fail "Unexpected return from multi-result-query: Unit"
          ~query ~arguments
      | `Tuples more -> more
      end
    end

  let in_transaction t ~f =
    Lwt_mutex.with_lock t.action_mutex begin fun () ->
      exec_unit t ~query:"BEGIN"
      >>= fun () ->
      begin
        f ()
        >>< function
        | `Ok o ->
          exec_unit t ~query:"COMMIT"
          >>= fun () ->
          return o
        | `Error e ->
          exec_unit t ~query:"ROLLBACK"
          >>= fun () ->
          fail e
      end
    end

  let close t =
    in_posix_thread_or_error ~loc:`Close begin fun () ->
      t.handle#finish
    end

end

(** Ketrew's 3-tables schema.
    
    - The main table is ["ketrew_main"], it contains all the
      workflow-nodes in a “denormalized” way.
    - The 2 other tables are staging areas for adding and killing sets
      of nodes.

*)
module Schema = struct

  module Parameters = struct
    type t = {
      main_table_name: string;
      kill_table_name: string;
      add_table_name: string;
    }
    let default = {
      main_table_name = "ketrew_main";
      kill_table_name = "ketrew_kill_list";
      add_table_name = "ketrew_add_list";
    }
  end
  open Parameters


  open SQL

  type id = Id
  let id = Field.byte_array Id "id"
  type blob = Blob
  let blob = Field.byte_array Blob "blob"

  module Engine_status = struct
    type t =
      [ `Passive | `Active | `Finished ]
    let to_string : t -> string =
      function
      | `Passive -> "passive"
      | `Active -> "active"
      | `Finished -> "finished"
    let of_string =
      function
      |  "passive"  -> Some `Passive
      |  "active"   -> Some `Active
      |  "finished" -> Some `Finished
      | _ -> None
  end
  type engine_status = Engine_status
  let engine_status =
    Field.stringable Engine_status "engine_status" (module Engine_status)

  module Id_list = struct
    type t = string list
    let to_string : t -> string = String.concat ~sep:", "
    let of_string s =
      String.split ~on:(`Character ',') s
      |> List.map ~f:String.strip
      |> List.filter ~f:((<>) "") 
      |> fun s -> Some s
  end
  type id_list = Id_list
  let id_list name =
    Field.stringable Id_list name (module Id_list)

  module Node_list = struct
    type t = Target.t list
    let to_string : t -> string = fun tl ->
      let yoj =
        `List (List.map tl ~f:Target.to_yojson) in
      Yojson.Safe.pretty_to_string yoj
    let of_string s =
      try
        Some (
          Yojson.Safe.from_string s
          |> function
          | `List l ->
            List.map l ~f:(fun j ->
                match Target.of_yojson j with
                | Ok o -> o
                | Error e -> failwith e)
          | other ->
            failwith ""
              )
      with _ ->
        None
  end
  type node_list = Node_list
  let node_list name =
    Field.stringable Node_list name (module Node_list)

  let main p =
    Table.(
      make p.main_table_name Field.List.[id; blob; engine_status]
    )

  let kill_list p =
    Table.(
      make p.kill_table_name Field.List.[id; id_list "ids_to_kill"]
    )

  let add_list p =
    Table.(
      make p.add_table_name Field.List.[id; node_list "nodes_to_add"]
    )

  let get_node p ~id:tid =
    select
      Field.List.[blob]
      ~from:(main p)
      ~where:Logic.Infix.(id === tid)
      begin fun (blob, Blob) ->
        match Target.Stored_target.deserialize blob with
        | `Ok st ->  st
        | `Error (`Target (`Deserilization msg)) ->
          failwith (fmt "Node-deserialization: %s" msg)
      end

  let insert_stored_node p ~node =
    insert (main p)
      (Target.Stored_target.id node, Id)
      (Target.Stored_target.serialize node, Blob)
      (`Passive, Engine_status)

  let update_node p ~engine_status:es ~node =
    let tid = Target.id node in
    update ~table:(main p)
      ~where:Logic.Infix.(id === tid)
      Field.List.[blob; engine_status]
      Target.Stored_target.(serialize (of_target node), Blob)
      (es, Engine_status)

  let all_nodes ?where p =
    select
      Field.List.[blob]
      ~from:(main p)
      ?where
      begin fun (blob, Blob) ->
        match Target.Stored_target.deserialize blob with
        | `Ok st ->  st
        | `Error (`Target (`Deserilization msg)) ->
          failwith (fmt "Node-deserialization: %s" msg)
      end

  let all_active_targets p =
    all_nodes p ~where:Logic.Infix.(engine_status === `Active)

  let all_active_and_passive_targets p =
    all_nodes p ~where:Logic.Infix.((engine_status === `Active)
                                    ||| (engine_status === `Passive))

  let add_to_kill_list p id_list =
    let kill_list_id = Unique_id.create () in
    insert (kill_list p)
      (kill_list_id, Id)
      (id_list, Id_list)

  let add_to_add_list p node_list =
    let add_list_id = Unique_id.create () in
    insert (add_list p)
      (add_list_id, Id)
      (node_list, Node_list)

  let get_the_kill_list p =
    let kl = kill_list p in
    select kl.Table.fields ~from:kl begin fun (id, Id) (id_list, Id_list) ->
      (`Kill_id id, `Ids_to_kill id_list)
    end

  let get_the_add_list p =
    let add = add_list p in
    select add.Table.fields ~from:add begin fun (id, Id) (list, Node_list) ->
      (`Addition_id id, `Nodes_to_add list)
    end

  let remove_from_kill_list p kid =
    delete ~from:(kill_list p) ~where:Logic.Infix.(id === kid) ()

  let remove_from_add_list p aid =
    delete ~from:(add_list p) ~where:Logic.Infix.(id === aid) ()

  let test_pg () =
    let p q =
      Printf.printf "QUERY: %s\n%!" (show_query q)
    in
    let params = Parameters.default in
    p (SQL.Table.to_sql_create (main params));
    let node = Target.create ~name:"Test" () in
    p (update_node params ~engine_status:`Passive ~node);
    p (get_node params ~id:"kjdeij" |> fst);
    p (insert_stored_node params ~node:(Target.Stored_target.of_target node));
    p (get_the_kill_list params |> fst);
    p (all_active_and_passive_targets params |> fst);
    ()

  let () =
    dbg "TEST_PGSQL";
    match Sys.getenv "TEST_PGSQL" with
    | "true" ->
      test_pg ()
    | _ -> ()
    | exception _ -> ()
end


(** Rate-limited stream of events using {!Lwt_react}. *)
module Event_source = struct
  type 'a t = {
    stream: 'a list Lwt_stream.t;
    trigger: 'a -> unit;
  }
  let create () =
    let base_event, trigger = React.E.create () in
    let stream =
      let last_return = ref None in
      let stream = Lwt_react.E.to_stream base_event in
      let rate_limit = 2.0 in
      let max_wait = 1.0 in
      Lwt_stream.from Lwt.(fun () ->
          let rec loop count acc =
            (* Count is used only for debug printing *)
            Lwt.pick [
              begin
                Lwt_stream.next stream
                >>= fun evalue ->
                return (evalue :: acc)
              end;
              begin
                Lwt_unix.sleep max_wait >>= fun _ -> return acc
              end;
            ]
            >>= fun new_values ->
            begin match !last_return with
            | None ->
              last_return := Some (Time.now ());
              loop (count + 1) new_values
            | Some t ->
              let now = Time.now () in
              begin match now -. t < rate_limit with
              | true ->
                loop (count + 1) new_values
              | false when new_values = [] ->
                loop (count + 1) new_values
              | false ->
                last_return := Some now;
                return (Some (new_values |> List.dedup))
              end
            end
          in
          loop 0 []
        )
    in
    {stream; trigger}
  let trigger {trigger; _} e =
    trigger e
  let stream {stream; _} = stream
end

(** “Changes” are the particular events of Ketrew's persistence layer. *)
module Change = struct
  type t = [ `Started | `New_nodes of string list | `Nodes_changed of string list ]
    [@@deriving show]
end


type t = {
  handle: DB.t;
  schema_parameters: Schema.Parameters.t;
  conninfo: string;
  action_mutex: Lwt_mutex.t;
  changes : Change.t Event_source.t;
}

module Error = struct
  type fetching_node = [
    | `Get_stored_target
    | `Pointer_loop_max_depth of int
    | `Target_to_add
  ] * [ `Id of string ]

  type database =
    [
      | `Exec of string * [ `Blob of string | `Null ] array
      | `Load of string
      | `Parsing of string
      | `Close
    ]
    * [ `Exn of string ]

  let database_to_string (loc, err) =
    fmt "Location: %s --- Error: %s"
      (match loc with
      | `Exec (s, _) -> fmt "executing %S" s
      | `Close -> "Closing"
      | `Parsing s -> fmt "Parsing (%s)" s
      | `Load s -> fmt "loading the DB: %S" s)
      (match err with
      | `Exn s -> s)

  let make l r : [> `Database of database ] = `Database (l, r)

  let wrap_parsing ~msg f =
    match f () with
    | some -> return some
    | exception e -> fail (`Database (`Parsing msg, `Exn (Printexc.to_string e)))
end

let create :
  database_parameters:string ->
  (t,
   [> `Database of Error.database ])
    Deferred_result.t
  = fun ~database_parameters ->
    let action_mutex = Lwt_mutex.create () in
    DB.create database_parameters
    >>= fun handle ->
    let schema_parameters = Schema.Parameters.default in
    let create_table table =
      let {SQL.query; arguments} =
        SQL.Table.to_sql_create table in
      DB.exec_unit handle ~query ~arguments
    in
    create_table Schema.(main schema_parameters) >>= fun () ->
    create_table Schema.(kill_list schema_parameters) >>= fun () ->
    create_table Schema.(add_list schema_parameters) >>= fun () ->
    let changes = Event_source.create () in
    return {handle; schema_parameters; action_mutex;
            conninfo = database_parameters; changes}

let unload: t ->
  (unit, [> `Database of  Error.database ]) Deferred_result.t
  = fun {handle; _} ->
    DB.close handle

let next_changes: t -> (Change.t list, 'a) Deferred_result.t = fun t ->
  Lwt.(
    Printf.eprintf "next_changes called\n%!";
    Lwt_stream.next (Event_source.stream t.changes)
    >>= fun change ->
    return (`Ok change)
  )

let get_target:
  t ->
  Target.id ->
  (Ketrew_pure.Target.t, [> `Database of Error.database]) Deferred_result.t
  = fun t id ->
    let rec get_following_pointers ~key ~count =
      let {SQL.query; arguments}, parse_result =
        Schema.get_node t.schema_parameters key in
      DB.exec_one t.handle ~query ~arguments
      >>= fun blist ->
      let msg = fmt "get_node/target %s" key in
      Error.wrap_parsing ~msg (fun () -> parse_result blist)
      >>= fun stored_node ->
      begin match Target.Stored_target.get_target stored_node with
      | `Pointer _ when count >= 1000 ->
        fail (`Fetching_node (`Pointer_loop_max_depth 1000, `Id id))
      | `Pointer key ->
        get_following_pointers ~count:(count + 1) ~key
      | `Target t -> return t
      end
    in
    get_following_pointers ~key:id ~count:0

let all_visible_targets :
  t ->
  (Ketrew_pure.Target.t list, [> `Database of Error.database]) Deferred_result.t
  = fun t ->
    (* TODO: should be removed and its dependencies too *)
    Printf.eprintf "all_visible_targets called\n%!";
    let {SQL.query; arguments}, parse_row =
      Schema.all_nodes t.schema_parameters in
    DB.exec_multi t.handle ~query ~arguments
    >>= fun rows ->
    Deferred_list.while_sequential rows ~f:begin fun row ->
      Error.wrap_parsing ~msg:"all_visible_targets"
        (fun () -> parse_row row)
    end
    >>= fun stored ->
    let only_targets =
      List.filter_map stored ~f:(fun st ->
          match Target.Stored_target.get_target st with
          | `Pointer _ -> None
          | `Target t -> Some t
        ) in
    return only_targets

(** Update node while not in a transaction. *)
let update_target_internal :
  t ->
  Target.t ->
  (unit,
   [> `Database of Error.database]) Deferred_result.t
  = fun t node ->
    let {SQL.query; arguments} =
      let engine_status =
        match Target.state node with
        | p when Target.State.Is.passive p -> `Passive
        | p when Target.State.Is.finished p -> `Finished
        | p -> `Active in
      Schema.update_node t.schema_parameters
        ~engine_status ~node
    in
    DB.exec_unit t.handle ~query ~arguments

(** This is the exported one; should not be reused inside a transaction. *)
let update_target :
  t ->
  Target.t ->
  (unit,
   [> `Database of Error.database ])
    Deferred_result.t
  = fun t node ->
    DB.in_transaction t.handle (fun () ->
        update_target_internal t node
      )
    >>= fun () ->
    Event_source.trigger t.changes (`Nodes_changed [Target.id node]);
    return ()

let activate_target :
  t ->
  target:Target.t ->
  reason:[ `Dependency of Target.id | `User ] ->
  (unit, [> `Database of Error.database]) Deferred_result.t
  = fun t ~target ~reason ->
    let newone = Target.(activate_exn target ~reason) in
    (* update_target already creates the transaction/action-mutex,
       and calls the `Event_source.trigger` *)
    update_target t newone

let fold_active_targets :
  t ->
  init:'a ->
  f:('a ->
     target:Target.t ->
     ('a,
      [> `Database of Error.database ] as 'combined_errors)
       Deferred_result.t) ->
  ('a, 'combined_errors) Deferred_result.t
  = fun t ~init ~f ->
    let {SQL.query; arguments}, parse_result =
      Schema.all_active_targets t.schema_parameters in
    DB.exec_multi t.handle ~query ~arguments
    >>= fun blist ->
    List.fold blist ~init:(return init) ~f:(fun prev_m row ->
        prev_m
        >>= fun prev ->
        let msg = fmt "fold_active_targets/target" in
        Error.wrap_parsing ~msg (fun () -> parse_result row)
        >>= fun stored_node ->
        begin match Target.Stored_target.get_target stored_node with
        | `Pointer key ->
          let err = fmt "Database is inconsistent: pointer %s is active." key in
          fail (Error.make (`Parsing msg) (`Exn err))
        | `Target t ->
          f prev ~target:t
        end
      )

let all_active_and_passive_nodes t =
  let {SQL.query; arguments}, parse_row =
    Schema.all_active_and_passive_targets t.schema_parameters in
  DB.exec_multi t.handle ~query ~arguments
  >>= fun rows ->
  Deferred_list.while_sequential rows ~f:begin fun row ->
    Error.wrap_parsing ~msg:"all_active_and_passive_targets"
      (fun () -> parse_row row)
  end

let target_strict_state trgt =
  let is_finished = Target.(state trgt |> State.Is.finished) in
  let is_passive = Target.(state trgt |> State.Is.passive) in
  begin match is_finished, is_passive with
  | true, true -> assert false
  | true, false -> `Finished
  | false, true -> `Passive
  | false, false -> `Active
  end

(** [find_all_orphans] goes through the DB and returns all the targets that
    are passive but not reachable, i.e. that can't be activated any
    more, ever.

    The implementation follows 3 steps:

    - Collect all the active and passive targets;
    - Follow all edges from the active ones, to find the reachable passives;
    - Substract the above from all the passives.

    The definition of active is here quite conservative, cf.
    {!target_strict_state}.

    The function logs at the end; one can trace it with
    ["debug_log_functions=find_all_orphans"].

*)
let find_all_orphans:
  t ->
  (Ketrew_pure.Target.t list,
   [> `Database of Error.database ]) Deferred_result.t
  = fun t ->
    let log_items = ref Display_markup.[
        "function", text "find_all_orphans";
        "start", date_now ();
      ] in
    all_active_and_passive_nodes t
    >>= fun active_and_passive ->
    log_items := !log_items @ Display_markup.[
        "got-all-actives-passives", date_now ();
      ];
    List.fold active_and_passive
      ~init:(return (`Passives [], `Actives []))
      ~f:begin fun prev_m stored ->
        prev_m >>= fun ((`Passives pl, `Actives al) as prev) ->
        begin match Target.Stored_target.get_target stored with
        | `Pointer id ->
          return prev
        | `Target trgt ->
          begin match target_strict_state trgt with
          | `Finished -> return prev
          | `Passive -> return (`Passives (trgt :: pl), `Actives al)
          | `Active -> return (`Passives pl, `Actives (trgt :: al))
          end
        end
      end
    >>= fun (`Passives passives, `Actives actives)->
    log_items := !log_items @ Display_markup.[
        "actives", big_itemize actives
          ~render:Target.(fun st -> textf "%s (%s)" (id st) (name st));
        "passives", textf "%d targets" (List.length passives);
      ];
    let to_check = ref actives in
    let checked = ref [] in
    let rec reachable_passives acc () =
      match !to_check with
      | [] -> return acc
      | one :: more when List.exists !checked ~f:Target.(fun c -> id c = id one) ->
        to_check := more;
        reachable_passives acc ()
      | one :: more ->
        checked := one :: !checked;
        to_check := more;
        let all_edges =
          Target.depends_on one
          @ Target.on_failure_activate one
          @ Target.on_success_activate one
        in
        List.fold all_edges ~init:(return []) ~f:(fun prev_m id ->
            prev_m >>= fun prev ->
            get_target t id (* we actively want to follow pointers to find them
                               all *)
            >>= fun trgt ->
            begin match target_strict_state trgt with
            | `Finished -> return prev
            | `Passive ->
              to_check := trgt :: !to_check;
              return (trgt :: prev)
            | `Active ->
              to_check := trgt :: !to_check;
              return prev
            end
          )
        >>= fun passives ->
        reachable_passives (acc @ passives) ()
    in
    reachable_passives [] ()
    >>| List.dedup ~compare:(fun a b -> compare (Target.id a) (Target.id b))
    >>= fun reachable ->
    log_items := !log_items @ Display_markup.[
        "reachable", big_itemize reachable
          ~render:Target.(fun st -> textf "%s (%s)" (id st) (name st));
      ];
    let unreachable_passives =
      List.filter passives ~f:(fun p ->
          List.for_all reachable ~f:(fun rp -> Target.id rp <> Target.id p))
    in
    log_items := !log_items @ Display_markup.[
        "unreachable", big_itemize unreachable_passives
          ~render:Target.(fun st -> textf "%s (%s)" (id st) (name st));
        "end", date_now ();
      ];
    Logger.log Display_markup.(description_list !log_items);
    return unreachable_passives


module Killing_targets = struct

  let proceed_to_mass_killing :
    t ->
    (bool,
     [> `Database of Error.database]) Deferred_result.t
    = fun t ->
      (*
         - select all from kill-list
         - create **transaction** per kill-list:
             - make target active and then Target.kill -> update_target
             - delete kill list entries
      *)
      let {SQL.query; arguments}, parse_row =
        Schema.get_the_kill_list t.schema_parameters in
      DB.exec_multi t.handle ~query ~arguments
      >>= fun rows ->
      List.fold rows ~init:(return false) ~f:begin fun prev_m row ->
        prev_m
        >>= fun prev ->
        let msg = fmt "proceed_to_mass_killing" in
        Error.wrap_parsing ~msg (fun () -> parse_row row)
        >>= fun (`Kill_id kid, `Ids_to_kill ks) ->
        DB.in_transaction t.handle ~f:begin fun () ->
          Deferred_list.while_sequential ks ~f:begin fun id ->
            get_target t id
            >>= fun target ->
            begin match Target.kill target with
            | Some new_node ->
              update_target_internal t new_node (* we are inside a transaction *)
              >>= fun () ->
              Event_source.trigger t.changes
                (`Nodes_changed [Target.id target]);
              return true
            | None ->
              return false
            end
            >>= fun something_changed ->
            let {SQL.query; arguments} =
              Schema.remove_from_kill_list t.schema_parameters kid in
            DB.exec_unit t.handle ~query ~arguments
            >>= fun () ->
            return something_changed
          end
        end
        >>= fun potential_changes ->
        return (List.exists ~f:(fun x -> x) potential_changes || prev)
      end

  let add_target_ids_to_kill_list :
    t ->
    string list ->
    (unit,
     [> `Database of Error.database ]) Deferred_result.t
    = fun t id_list ->
      let {SQL.query; arguments} =
        Schema.add_to_kill_list t.schema_parameters id_list in
      DB.in_transaction t.handle begin fun () ->
        DB.exec_unit t.handle ~query ~arguments
      end
end

module Adding_targets = struct

  (** Bypass the normal flow of target addition and put a target in the DB. *)
  let force_add_passive_target: t ->
    Ketrew_pure.Target.t ->
    (unit,
     [> `Database of Error.database ]) Deferred_result.t
    = fun t trgt ->
      let st = Target.Stored_target.of_target trgt in
      let {SQL.query; arguments} =
        Schema.insert_stored_node t.schema_parameters st in
      DB.in_transaction t.handle begin fun () ->
        DB.exec_unit t.handle ~query ~arguments
      end

  let register_targets_to_add :
    t ->
    Target.t list ->
    (unit,
     [> `Database of Error.database ])
      Deferred_result.t
    = fun t nodes ->
      let {SQL.query; arguments} =
        Schema.add_to_add_list t.schema_parameters nodes in
      DB.in_transaction t.handle begin fun () ->
        DB.exec_unit t.handle ~query ~arguments
      end


  (** Internal “pure” function: transforms [new_nodes] a list of
      [Target.t]'s into a list of [Target.Stored_target.t]'s by
      checking equivalence against [active_or_passive_nodes] and
      “itself” (i.e. each non-equivalent node becomes part of the
      equivalence checking for the following nodes).
  *)
  let compute_equivalence ~new_nodes ~active_or_passive_nodes =
    let stuff_to_actually_add =
      List.fold ~init:[] new_nodes ~f:begin fun to_store_targets target ->
        let equivalences =
          let we_kept_so_far =
            List.filter_map to_store_targets
              ~f:(fun st ->
                  match Target.Stored_target.get_target st with
                  | `Target t -> Some t
                  | `Pointer _ -> None) in
          List.filter (active_or_passive_nodes @ we_kept_so_far)
            ~f:(fun t -> Target.is_equivalent target t) in
        Log.(Target.log target % s " is "
             % (match equivalences with
               | [] -> s "pretty fresh"
               | more ->
                 s " equivalent to " % OCaml.list Target.log equivalences)
             @ very_verbose);
        match equivalences with
        | [] ->
          (Target.Stored_target.of_target target :: to_store_targets)
        | at_least_one :: _ ->
          (
            if Target.State.Is.activated_by_user (Target.state target)
            then
              Logging.User_level_events.root_workflow_equivalent_to
                ~name:(Target.name target)
                ~id:(Target.id target)
                (List.map equivalences ~f:(fun st ->
                     (Target.name st, Target.id st)))
          );
          (Target.Stored_target.make_pointer
             ~from:target ~pointing_to:at_least_one :: to_store_targets)
      end
    in
    log_info
      Log.(s "Going to add new " % i (List.length stuff_to_actually_add)
           % s " targets to the DB"
           % (parens (i (List.length new_nodes)
                      % s " were submitted")));
    stuff_to_actually_add


  let check_and_really_add_targets :
    t ->
    (bool,
     [> `Database of Error.database ]) Deferred_result.t
    = fun t ->
      (*
      - get targets to add
      - get all activable & active targets
      - for each “batch”
          - do equivalence dance
          - transaction:
              - add to the database
              - remove from the add-list
      *)
      let {SQL.query; arguments}, parse_row =
        Schema.get_the_add_list t.schema_parameters in
      DB.exec_multi t.handle ~query ~arguments
      >>= fun rows ->
      List.fold rows ~init:(return false) ~f:begin fun prev_m row ->
        prev_m
        >>= fun prev ->
        let msg = fmt "really_adding_nodes" in
        Error.wrap_parsing ~msg (fun () -> parse_row row)
        >>= fun (`Addition_id aid, `Nodes_to_add nodes_to_add) ->
        all_active_and_passive_nodes t
        >>= fun all_interesting_nodes ->
        let nodes_to_really_add =
          let active_or_passive_nodes =
            List.filter_map all_interesting_nodes
              ~f:(fun t ->
                  match Target.Stored_target.get_target t with
                  | `Target t -> Some t
                  | `Pointer _ -> None) in
          compute_equivalence
            ~new_nodes:nodes_to_add
            ~active_or_passive_nodes in
        (* Now the writing in the DB: *)
        DB.in_transaction t.handle ~f:begin fun () ->
          Deferred_list.while_sequential nodes_to_really_add ~f:begin fun st ->
            let {SQL.query; arguments} =
              Schema.insert_stored_node t.schema_parameters st in
            DB.exec_unit t.handle ~query ~arguments
            >>= fun () ->
            (* If not-a-pointer we force the update to catch all the things
               to catch. TODO: should be done in one query. *)
            begin match Target.Stored_target.get_target st with
            | `Target trgt ->
              update_target_internal t trgt
            |`Pointer _ ->
              return ()
            end
            >>= fun () ->
            let {SQL.query; arguments} =
              Schema.remove_from_add_list t.schema_parameters aid in
            DB.exec_unit t.handle ~query ~arguments
          end
        end
        >>= fun (_ : unit list) ->
        begin match nodes_to_really_add with
        | [] -> return prev
        | more ->
          Event_source.trigger t.changes
            (`New_nodes (List.map ~f:Target.Stored_target.id more));
          return true
        end
      end
end

module Synchronize = struct

  let make_input spec ~f =
    let uri = Uri.of_string spec in
    match Uri.scheme uri with
    | Some "backup" ->
      let path  = Uri.path uri in
      let rec go ~path =
        System.file_info path
        >>= begin function
        | `Symlink _
        | `Socket
        | `Fifo
        | `Block_device
        | `Character_device -> fail (`Weird_file path)
        | `Absent -> fail (`Weird_file path)
        | `Regular_file _ ->
          IO.read_file path
          >>= fun d ->
          of_result (Target.Stored_target.deserialize d)
          >>= fun st ->
          f st
        | `Directory ->
          let `Stream next = System.list_directory path in
          let rec go_inside () =
            next ()
            >>= function
            | None -> return ()
            | Some ".."
            | Some "." ->
              go_inside ()
            | Some s ->
              go ~path:(path // s)
              >>= fun () ->
              go_inside ()
          in
          go_inside ()
        end
      in
      go ~path
    | Some "postgresql" ->
      create ~database_parameters:spec
      >>= fun t ->
      let {SQL.query; arguments}, parse_row =
        Schema.all_nodes t.schema_parameters in
      DB.exec_multi t.handle ~query ~arguments
      >>= fun rows ->
      Deferred_list.while_sequential rows ~f:begin fun row ->
        Error.wrap_parsing ~msg:"Synchronize.make_input"
          (fun () -> parse_row row)
      end
      >>= fun stored ->
      Deferred_list.while_sequential stored ~f:(fun s -> f s)
      >>= fun (_ : unit list) ->
      unload t
    | other ->
      fail (`Unknown_uri_scheme (spec, other))

  let make_output spec =
    let uri = Uri.of_string spec in
    match Uri.scheme uri with
    | Some "backup" ->
      let path  = Uri.path uri in
      let in_directory = ref 0 in
      let dir_name n = fmt "hecto_%06d" n in 
      let current_directory = ref 0 in
      let next_dir () =
        if !in_directory >= 100 then (
          in_directory := 0;
          incr current_directory;
        ) else (
          incr in_directory;
        );
        dir_name !current_directory in
      let store stored_target =
        let save_path = path // next_dir () in
        System.ensure_directory_path save_path
        >>= fun () ->
        IO.write_file (save_path
                       // Target.Stored_target.id stored_target ^ ".json")
          ~content:(Target.Stored_target.serialize stored_target)
      in
      return (object
        method store st = store st
        method close = return ()
      end)
    | Some "postgresql" ->
      create ~database_parameters:spec
      >>= fun t ->
      let store st =
        let {SQL.query; arguments} =
          Schema.insert_stored_node t.schema_parameters st in
        DB.in_transaction t.handle begin fun () ->
          DB.exec_unit t.handle ~query ~arguments
          >>= fun () ->
          begin match Target.Stored_target.get_target st with
          | `Target trgt ->
            update_target_internal t trgt
          |`Pointer _ ->
            return ()
          end
        end
      in
      return (object
        method store st = store st
        method close = unload t
      end)
    | other ->
      fail (`Unknown_uri_scheme (spec, other))


  let copy src dst =
    begin
      make_output dst
      >>= fun output ->
      make_input src ~f:(fun st -> output#store st)
      >>= fun () ->
      output#close
    end >>< function
    | `Ok () -> return ()
    | `Error e -> fail (`Syncronize (src, dst, e))

  module Error = struct
    let to_string (src, dst, e) =
      fmt "Sync: %s -> %s: %s" src dst @@
      match e with
      | `Database d -> Error.database_to_string d
      | `IO _ as e ->
        Pvem_lwt_unix.IO.error_to_string e
      | `System _ as e ->
        Pvem_lwt_unix.System.error_to_string e
      | `Unknown_uri_scheme (url, sch) ->
        fmt "Unknown URI scheme: %S" url
      | `Weird_file path ->
        fmt "Not a regular file or directory: %s" path
      | `Target (`Deserilization s) ->
        fmt "Target deserialization error: %S" s

  end
end

