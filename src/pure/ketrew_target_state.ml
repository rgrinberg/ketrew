(**************************************************************************)
(*  Copyright 2015, Sebastien Mondet <seb@mondet.org>                     *)
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



module State = struct
(**
Encoding of the state of a target:
   
- `run_bookkeeping` keeps the information for the `Long_running` plugin.
- `log` is a time stamped optional log message

Every state point to its previous state through a `'a hitory`. 

We use the subtyping of  polymorphic variants to encode the
state-machine; a given state can come only from certain previous
states, those are enforced with the type-parameter of the `history`
value.

*)
  type run_bookkeeping = 
    { plugin_name: string; run_parameters: string } [@@deriving yojson]
  type log = {
    (* time: Time.t; *)
    time: float;
    message: string option;
  } [@@deriving yojson]
  type 'a history = {
    log: log;
    previous_state: 'a;
  } [@@deriving yojson]
  type id = string
      [@@deriving yojson]
  type passive = [ `Passive of log ] [@@deriving yojson]
  type active = [
    | `Active of (passive history * [ `User | `Dependency of id ])
  ] [@@deriving yojson]
  type evaluating_condition = [
    | active
    | `Tried_to_eval_condition of evaluating_condition history
  ] [@@deriving yojson]
  type already_done = [
    | `Already_done of evaluating_condition history
  ] [@@deriving yojson]
  type building = [
    | `Building of evaluating_condition history
    | `Still_building of building history
  ] [@@deriving yojson]
  type dependency_failure = [
    | `Dependencies_failed of (building history * id list)
  ] [@@deriving yojson]
  type starting = [
    | `Starting of building history
    | `Tried_to_start of (starting history * run_bookkeeping)
  ] [@@deriving yojson]
  (* let starting_of_yojson yj : ([< starting ], _) Result.t = starting_of_yojson yj *)
  type failed_to_start = [
    | `Failed_to_eval_condition of evaluating_condition history
    | `Failed_to_start of (starting history * run_bookkeeping)
  ] [@@deriving yojson]
  type running = [
    | `Started_running of (starting history * run_bookkeeping)
    | `Still_running  of (running history * run_bookkeeping)
    | `Still_running_despite_recoverable_error of
        (string * running history * run_bookkeeping)
  ] [@@deriving yojson]
(*
Successful run is the success of the process, we still have to verify
that the potential condition has been ensured.
*)
  type successful_run = [
    | `Successfully_did_nothing of starting history
    | `Ran_successfully of (running history * run_bookkeeping)
    | `Tried_to_reeval_condition of (string * successful_run history)
  ] [@@deriving yojson]
  type process_failure_reason = [
    (* | Did_not_ensure_condition of string *)
    | `Long_running_failure of string
  ] [@@deriving yojson]
  type failed_run = [
    | `Failed_running of
        (running history * process_failure_reason * run_bookkeeping)
  ] [@@deriving yojson]
  type verified_run = [
    | `Verified_success of successful_run history
  ] [@@deriving yojson]
  type failed_to_verify_success = [
    | `Did_not_ensure_condition of successful_run history
  ] [@@deriving yojson]
  type killable_state = [
    | passive
    | evaluating_condition
    | building
    | starting
    | running
  ] [@@deriving yojson]
  type killing = [
    | `Killing of killable_state history
    | `Tried_to_kill of killing history
  ] [@@deriving yojson]
  type killed = [
    | `Killed of killing history
  ] [@@deriving yojson]
  type failed_to_kill = [
    | `Failed_to_kill of killing history
  ] [@@deriving yojson]
  type finishing_state = [
    | failed_run
    | verified_run
    | already_done
    | dependency_failure
    | failed_to_start
    | killed
    | failed_to_kill
    | failed_to_verify_success
  ] [@@deriving yojson]
  type finished = [
    | `Finished of finishing_state history
  ] [@@deriving yojson]
  type t = [
    | killing
    | killed
    | killable_state
    | successful_run
    | finishing_state
    | finished
  ] [@@deriving yojson]

  let of_yojson yj : (t, _) Result.t = of_yojson yj


  let make_log ?message () = 
    {time = Time.now (); message}
  let to_history ?log previous_state =
    {log = make_log ?message:log (); previous_state}

  let rec simplify (t: t) =
    match t with
    | `Building _
    | `Tried_to_start _
    | `Started_running _
    | `Starting _
    | `Still_building _
    | `Still_running _
    | `Still_running_despite_recoverable_error _
    | `Ran_successfully _
    | `Successfully_did_nothing _
    | `Tried_to_eval_condition _
    | `Tried_to_reeval_condition _
    | `Active _ -> `In_progress
    | `Verified_success _
    | `Already_done _ -> `Successful
    | `Dependencies_failed _
    | `Failed_running _
    | `Failed_to_kill _
    | `Failed_to_start _
    | `Failed_to_eval_condition _
    | `Killing _
    | `Tried_to_kill _
    | `Did_not_ensure_condition _
    | `Killed _ -> `Failed
    | `Finished s ->
      simplify (s.previous_state :> t)
    | `Passive _ -> `Activable

  let rec passive_time (t: t) =
    let continue history =
      passive_time (history.previous_state :> t)
    in
    match t with
    | `Building history -> continue history
    | `Tried_to_start (history, _) -> continue history
    | `Started_running (history, _) -> continue history
    | `Starting history -> continue history
    | `Still_building history -> continue history
    | `Still_running (history, _) -> continue history
    | `Still_running_despite_recoverable_error (_, history, _) -> continue history
    | `Ran_successfully (history, _) -> continue history
    | `Successfully_did_nothing history -> continue history
    | `Active (history, _) -> continue history
    | `Tried_to_eval_condition history -> continue history
    | `Tried_to_reeval_condition (_, history) -> continue history
    | `Verified_success history -> continue history
    | `Already_done history -> continue history
    | `Dependencies_failed (history, _) -> continue history
    | `Failed_running (history, _, _) -> continue history
    | `Failed_to_kill history -> continue history
    | `Failed_to_eval_condition history -> continue history
    | `Failed_to_start (history, _) -> continue history
    | `Killing history -> continue history
    | `Tried_to_kill history -> continue history
    | `Did_not_ensure_condition history -> continue history
    | `Killed history -> continue history
    | `Finished history -> continue history
    | `Passive log -> log.time

  let finished_time = function
  | `Finished {log; _} -> Some log.time
  | _ -> None

  let name (t: t) =
    match t with
    | `Building _ -> "Building"
    | `Tried_to_start _ -> "Tried_to_start"
    | `Started_running _ -> "Started_running"
    | `Starting _ -> "Starting"
    | `Still_building _ -> "Still_building"
    | `Still_running _ -> "Still_running"
    | `Still_running_despite_recoverable_error _ ->
      "Still_running_despite_recoverable_error"
    | `Ran_successfully _ -> "Ran_successfully"
    | `Successfully_did_nothing _ -> "Successfully_did_nothing"
    | `Active _ -> "Active"
    | `Tried_to_eval_condition _ -> "Tried_to_eval_condition"
    | `Tried_to_reeval_condition _ -> "Tried_to_reeval_condition"
    | `Verified_success _ -> "Verified_success"
    | `Already_done _ -> "Already_done"
    | `Dependencies_failed _ -> "Dependencies_failed"
    | `Failed_running _ -> "Failed_running"
    | `Failed_to_kill _ -> "Failed_to_kill"
    | `Failed_to_eval_condition _ -> "Failed_to_eval_condition"
    | `Failed_to_start _ -> "Failed_to_start"
    | `Killing _ -> "Killing"
    | `Tried_to_kill _ -> "Tried_to_kill"
    | `Did_not_ensure_condition _ -> "Did_not_ensure_condition"
    | `Killed _ -> "Killed"
    | `Finished _ -> "Finished"
    | `Passive _ -> "Passive"

  let rec latest_run_bookkeeping (t: t) =
    let continue history =
      latest_run_bookkeeping (history.previous_state :> t) in
    match t with
    | `Building history -> None
    | `Tried_to_start (hist, book) -> (Some book)
    | `Started_running (hist, book) -> (Some book)
    | `Starting history -> (None)
    | `Still_building history -> (None)
    | `Still_running (hist, book) -> (Some book)
    | `Still_running_despite_recoverable_error (_, hist, book) -> (Some book)
    | `Ran_successfully (hist, book) -> (Some book)
    | `Successfully_did_nothing history -> (None)
    | `Tried_to_eval_condition _ -> (None)
    | `Tried_to_reeval_condition (_, history) -> continue history
    | `Active (history, _) -> (None)
    | `Verified_success history -> continue history
    | `Already_done history -> None
    | `Dependencies_failed (history, _) -> (None)
    | `Failed_running (hist, _, book) -> (Some book)
    | `Failed_to_kill history -> continue history
    | `Failed_to_eval_condition history -> continue history
    | `Failed_to_start (hist, book) -> (Some book)
    | `Killing history -> continue history
    | `Tried_to_kill history -> continue history
    | `Did_not_ensure_condition history -> continue history
    | `Killed history -> continue history
    | `Finished history -> continue history
    | `Passive log -> (None)

  let contents (t: t) =
    let some h = Some (h :> t history) in
    match t with
    | `Building history -> (some history, None)
    | `Tried_to_start (hist, book) -> (some hist, Some book)
    | `Started_running (hist, book) -> (some hist, Some book)
    | `Starting history -> (some history, None)
    | `Still_building history -> (some history, None)
    | `Still_running (hist, book) -> (some hist, Some book)
    | `Still_running_despite_recoverable_error (_, hist, book) ->
      (some hist, Some book)
    | `Ran_successfully (hist, book) -> (some hist, Some book)
    | `Successfully_did_nothing history -> (some history, None)
    | `Active (history, _) -> (some history, None)
    | `Tried_to_eval_condition history -> (some history, None)
    | `Tried_to_reeval_condition (_, history) -> (some history, None)
    | `Verified_success history -> (some history, None)
    | `Already_done history -> (some history, None)
    | `Dependencies_failed (history, _) -> (some history, None)
    | `Failed_running (hist, _, book) -> (some hist, Some book)
    | `Failed_to_kill history -> (some history, None)
    | `Failed_to_eval_condition history -> (some history, None)
    | `Failed_to_start (hist, book) -> (some hist, Some book)
    | `Killing history -> (some history, None)
    | `Tried_to_kill history -> (some history, None)
    | `Did_not_ensure_condition history -> (some history, None)
    | `Killed history -> (some history, None)
    | `Finished history -> (some history, None)
    | `Passive log -> (None, None)

  let summary t =
    let rec count_start_attempts : starting history -> int = fun h ->
      match h.previous_state with 
      | `Starting _ -> 1
      | `Tried_to_start (hh, _) -> 1 + (count_start_attempts hh)
    in
    let rec count_kill_attempts : killing history -> int = fun h ->
      match h.previous_state with 
      | `Killing _ -> 1
      | `Tried_to_kill hh -> 1 + (count_kill_attempts hh)
    in
    let plural_of_int ?(y=false) n =
      match y, n with
      | true, 1 ->  "y"
      | true, _ -> "ies"
      | _, 1 ->  ""
      | _, _ -> "s" in
    let rec dive (t: t) =
      let continue history = dive (history.previous_state :> t) in
      match t with
      | `Building history -> continue history
      | `Tried_to_start (history, book) ->
        let attempts = count_start_attempts history in
        fmt " %d start-attempt%s" attempts (plural_of_int attempts)
        :: continue history
      | `Started_running (history, book) -> continue history
      | `Starting history -> continue history
      | `Still_building history -> continue history
      | `Still_running (history, book) -> continue history
      | `Still_running_despite_recoverable_error (error, history, book) ->
        fmt "non-fatal error %S (check-running)" error :: continue history
      | `Ran_successfully (history, book) -> continue history
      | `Successfully_did_nothing history -> continue history
      | `Active (history, _) -> continue history
      | `Tried_to_eval_condition history -> continue history
      | `Tried_to_reeval_condition (error, history) ->
        fmt "non-fatal error %S (eval-condition)" error :: continue history
      | `Verified_success history -> continue history
      | `Already_done history ->
        "already-done" :: continue history
      | `Dependencies_failed (history, deps) ->
        let nb_deps = (List.length deps) in
        fmt "%d depependenc%s failed" nb_deps (plural_of_int ~y:true nb_deps)
        :: continue history
      | `Failed_running (history, reason, book) ->
        fmt "Reason: %S" (match reason with | `Long_running_failure s -> s)
        :: continue history
      | `Failed_to_kill history -> continue history
      | `Failed_to_eval_condition history -> continue history
      | `Failed_to_start (history, book) ->
        continue history
      | `Killing history ->
        fmt "killed from %s" (name (history.previous_state :> t))
        :: continue history
      | `Tried_to_kill history ->
        fmt "%d killing-attempts" (count_kill_attempts history)
        :: continue history
      | `Did_not_ensure_condition history ->
        "Did_not_ensure_condition" :: continue history
      | `Killed history ->
        "killed" :: continue history
      | `Finished history -> continue history
      | `Passive log -> []
    in
    let history_opt, bookkeeping_opt = contents t in
    let time, message =
      Option.map history_opt ~f:(fun history ->
        let { log = {time; message}; previous_state } = history in
        (time, message))
      |> function
      | None -> passive_time t, None
      | Some (time, m) -> time, m in
    (`Time time, `Log message, `Info (dive t))

  let rec to_flat_list (t : t) =
    let make_item ?bookkeeping ~history name = 
        let { log; previous_state } = history in
        let bookkeeping_msg =
          Option.map bookkeeping ~f:(fun { plugin_name; run_parameters } ->
              fmt "[%s] Run-parameters: %d bytes" plugin_name
                (String.length run_parameters)) in
        (log.time, name, log.message, bookkeeping_msg)
        :: to_flat_list (previous_state :> t)
    in
    let name = name t in
    let history_opt, bookkeeping = contents t in
    match t with
    | `Passive log -> (* passive ! *)
      (log.time, name, log.message, None) :: []
    | other ->  
      let history =
        Option.value_exn history_opt ~msg:"non-passive got None history" in
      make_item ~history ?bookkeeping name

  let log ?depth t =
    to_flat_list t
    |> fun l ->
    begin match depth with
    | Some d -> List.take l d
    | None -> l
    end
    |> List.map ~f:(fun (time, name, msgopt, bookopt) ->
        Log.(s "* " % Time.log time % s ": " % s name
             % (match msgopt with None -> empty | Some m -> n % indent (s m))
             % (match bookopt with None -> empty | Some m -> n % indent (s m))))
    |> Log.(separate n)

  module Is = struct
    let building = function `Building _ -> true | _ -> false
    let tried_to_start = function `Tried_to_start _ -> true | _ -> false
    let started_running = function `Started_running _ -> true | _ -> false
    let starting = function `Starting _ -> true | _ -> false
    let still_building = function `Still_building _ -> true | _ -> false
    let still_running = function `Still_running _ -> true | _ -> false
    let ran_successfully = function `Ran_successfully _ -> true | _ -> false
    let successfully_did_nothing = function `Successfully_did_nothing _ -> true | _ -> false
    let active = function `Active _ -> true | _ -> false
    let tried_to_eval_condition = function `Tried_to_eval_condition _ -> true | _ -> false
    let verified_success = function `Verified_success _ -> true | _ -> false
    let already_done = function `Already_done _ -> true | _ -> false
    let dependencies_failed = function `Dependencies_failed _ -> true | _ -> false
    let failed_running = function `Failed_running _ -> true | _ -> false
    let failed_to_kill = function `Failed_to_kill _ -> true | _ -> false
    let failed_to_start = function `Failed_to_start _ -> true | _ -> false
    let failed_to_eval_condition = function `Failed_to_eval_condition _ -> true | _ -> false
    let killing = function `Killing _ -> true | _ -> false
    let tried_to_kill = function `Tried_to_kill _ -> true | _ -> false
    let did_not_ensure_condition = function `Did_not_ensure_condition _ -> true | _ -> false
    let killed = function `Killed _ -> true | _ -> false
    let finished = function `Finished _ -> true | _ -> false
    let passive = function `Passive _ -> true | _ -> false
  
    let killable = function
    | #killable_state -> true
    | _ -> false

    let finished_because_dependencies_died =
      function
      | `Finished {previous_state = (`Dependencies_failed _); _ } -> true
      | other -> false

  end
  
end

type t = {
  target: Ketrew_target.id;
  history: State.t;
} [@@deriving yojson]

let create ~target () =
  let history = `Passive (State.make_log ()) in
  {target; history}

let history t = t.history
                  
let with_history t h = {t with history = h}

let latest_run_parameters t =
  t.history
  |> State.latest_run_bookkeeping
  |> Option.map 
    ~f:(fun rb -> rb.State.run_parameters)

let activate_exn ?log t ~reason =
  match t.history with 
  | `Passive _ as c ->
    with_history t (`Active (State.to_history ?log c, reason))
  | _ -> raise (Invalid_argument "activate_exn")

let kill ?log t =
  match t.history with
  | #State.killable_state as c ->
    Some (with_history t (`Killing (State.to_history ?log c)))
  | other ->
    None

let reactivate
    ?with_id ?with_name ?with_metadata ?log t =
  (* It's [`Passive] so there won't be any [exn]. *)
  assert false
    (*
  activate_exn ~reason:`User
    {t with
     history = `Passive (State.make_log ?message:log ());
     id = Option.value with_id ~default:(Unique_id.create ());
     name = Option.value with_name ~default:t.name;
     metadata = Option.value with_metadata ~default:t.metadata}
*)

module Automaton = struct

      
  type failure_reason = State.process_failure_reason
  type progress = [ `Changed_state | `No_change ]
  type 'a transition_callback = ?log:string -> 'a -> t * progress
  type severity = [ `Try_again | `Fatal ]
  type bookkeeping = State.run_bookkeeping  =
    { plugin_name: string; run_parameters: string }
  type long_running_failure = severity * string * bookkeeping
  type long_running_action =  (bookkeeping, long_running_failure) Pvem.Result.t
  type process_check =
    [ `Successful of bookkeeping | `Still_running of bookkeeping ]
  type process_status_check = (process_check, long_running_failure) Pvem.Result.t
  type condition_evaluation = (bool, severity * string) Pvem.Result.t
  type dependencies_status = 
    [ `All_succeeded
    | `At_least_one_failed of Ketrew_target.id list | `Still_processing ]
  type transition = [
    | `Do_nothing of unit transition_callback
    | `Activate of Ketrew_target.id list * unit transition_callback
    | `Check_and_activate_dependencies of dependencies_status transition_callback
    | `Start_running of bookkeeping * long_running_action transition_callback
    | `Eval_condition of Ketrew_target.Condition.t * condition_evaluation transition_callback
    | `Check_process of bookkeeping * process_status_check transition_callback
    | `Kill of bookkeeping * long_running_action transition_callback
  ]

  open State

  let transition target state : transition =
    let open Ketrew_target in
    let return_with_history ?(no_change=false) t h =
      with_history t h, (if no_change then `No_change else `Changed_state) in
    let activate_fallbacks c =
      `Activate (fallbacks target, (fun ?log () ->
          return_with_history state (`Finished (to_history ?log c)))) in
    let activate_success_triggers c =
      `Activate (success_triggers target, (fun ?log () ->
          return_with_history state (`Finished (to_history ?log c)))) in
    let from_killing_state killable_history current_state =
      let{ log; previous_state } = killable_history in
      begin match previous_state with
      | `Building _
      | `Starting _
      | `Passive _
      | `Tried_to_start _
      | `Still_building _ (* should we ask to kill the dependencies? *)
      | `Tried_to_eval_condition _
      | `Tried_to_reeval_condition _
      | `Active _ ->
        `Do_nothing (fun ?log () ->
            return_with_history state (`Killed (to_history ?log current_state)))
      | `Still_running (_, bookkeeping)
      | `Still_running_despite_recoverable_error (_, _, bookkeeping)
      | `Started_running (_, bookkeeping) ->
        `Kill (bookkeeping, begin fun ?log -> function
          | `Ok bookkeeping -> (* loosing some bookeeping *)
            return_with_history state (`Killed (to_history ?log current_state))
          | `Error (`Try_again, reason, bookeeping) ->
            return_with_history ~no_change:true state
              (`Tried_to_kill (to_history ?log current_state))
          | `Error (`Fatal, reason, bookeeping) ->
            return_with_history state (`Failed_to_kill (to_history ?log current_state))
          end)
      end
    in
    begin match state.history with
    | `Finished _
    | `Passive _ ->
      `Do_nothing (fun ?log () -> state, `No_change)
    | `Tried_to_eval_condition _
    | `Active _ as c ->
      begin match condition target with
      | Some cond ->
        `Eval_condition (cond, begin fun ?log -> function
          | `Ok true -> return_with_history state (`Already_done (to_history ?log c))
          | `Ok false -> return_with_history state (`Building (to_history ?log c))
          | `Error (`Try_again, log)  ->
            return_with_history state ~no_change:true
              (`Tried_to_eval_condition (to_history ~log c))
          | `Error (`Fatal, reason)  ->
            return_with_history state (`Failed_to_eval_condition (to_history ?log c))
          end)
      | None ->
        `Do_nothing (fun ?log () ->
            return_with_history state (`Building (to_history ?log c)))
      end      
    | `Already_done _ as c ->
      activate_success_triggers c
    | `Still_building _
    | `Building _ as c ->
      `Check_and_activate_dependencies begin fun ?log -> function
      | `All_succeeded ->
        return_with_history state (`Starting (to_history ?log c))
      | `At_least_one_failed id_list ->
        return_with_history state (`Dependencies_failed (to_history ?log c, id_list))
      | `Still_processing ->
        return_with_history ~no_change:true state
          (`Still_building (to_history ?log c))
      end
    | `Did_not_ensure_condition _
    | `Dependencies_failed _ as c -> activate_fallbacks c
    | `Starting _
    | `Tried_to_start _ as c ->
      begin match build_process target with
      | `Long_running (plugin_name, created_run_paramters) ->
        let bookeeping =
          {plugin_name; run_parameters = created_run_paramters } in
        `Start_running (bookeeping, begin fun ?log -> function
          | `Ok bookkeeping ->
            return_with_history state (`Started_running (to_history ?log c, bookkeeping))
          | `Error (`Try_again, log, bookkeeping)  ->
            return_with_history state ~no_change:true
              (`Tried_to_start (to_history ~log c, bookkeeping))
          | `Error (`Fatal, reason, bookkeeping)  ->
            return_with_history state (`Failed_to_start (to_history ?log c, bookkeeping))
          end)
      | `No_operation ->
        `Do_nothing (fun ?log () ->
            return_with_history state (`Successfully_did_nothing (to_history ?log c)))
      end
    | `Started_running (_, bookkeeping)
    | `Still_running_despite_recoverable_error (_, _, bookkeeping)
    | `Still_running (_, bookkeeping) as c ->
      `Check_process (bookkeeping, begin fun ?log -> function
        | `Ok (`Still_running bookkeeping) ->
          return_with_history state ~no_change:true
            (`Still_running (to_history ?log c, bookkeeping))
        | `Ok (`Successful bookkeeping) ->
          return_with_history state (`Ran_successfully (to_history ?log c, bookkeeping))
        | `Error (`Try_again, how, bookkeeping) ->
          return_with_history state ~no_change:true
            (`Still_running_despite_recoverable_error
               (how, to_history ?log c, bookkeeping))
        | `Error (`Fatal, how, bookkeeping) -> 
          return_with_history state
            (`Failed_running (to_history ?log c,
                              `Long_running_failure how, bookkeeping))
        end)
    | `Successfully_did_nothing _
    | `Tried_to_reeval_condition _
    | `Ran_successfully _ as c ->
      begin match condition target with
      | Some cond ->
        `Eval_condition (cond, begin fun ?log -> function
          | `Ok true -> return_with_history state (`Verified_success (to_history ?log c))
          | `Ok false ->
            return_with_history state (`Did_not_ensure_condition (to_history ?log c))
          | `Error (`Try_again, how) ->
            return_with_history state ~no_change:true
              (`Tried_to_reeval_condition (how, to_history ?log c))
          | `Error (`Fatal,log)  ->
            return_with_history state (`Did_not_ensure_condition (to_history ~log c))
          end)
      | None ->
        `Do_nothing (fun ?log () ->
            return_with_history state (`Verified_success (to_history ?log c)))
      end      
    | `Verified_success _ as c ->
      activate_success_triggers c
    | `Failed_running _ as c ->
      activate_fallbacks c
    | `Tried_to_kill _ as c ->
      let killable_history =
        let rec go =
          function
          | `Killing h -> h
          | `Tried_to_kill {previous_state; _} ->
            go previous_state in
        (go c)
      in
      from_killing_state killable_history c
    | `Killing history as c ->
      from_killing_state history c
    | `Killed _
    | `Failed_to_start _
    | `Failed_to_eval_condition _
    | `Failed_to_kill _ as c ->
      (* what should we actually do? *)
      activate_fallbacks c
    end

end


