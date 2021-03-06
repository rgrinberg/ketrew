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

open Ketrew_pure
open Internal_pervasives
open Unix_io

type t

val create :
  database_parameters:string ->
  (t,
   [> `Database of Trakeva.Error.t
   | `Database_unavailable of bytes
   | `Missing_data of string
   | `Target of [> `Deserilization of string ] ])
    Deferred_result.t

val unload: t ->
  (unit, [> `Database of [> `Close ] * string ]) Deferred_result.t

val get_target:
  t ->
  Target.id ->
  (Ketrew_pure.Target.t,
   [> `Database of Trakeva.Error.t
   | `Database_unavailable of bytes
   | `Missing_data of string
   | `Target of [> `Deserilization of string ] ])
    Deferred_result.t

val all_targets :
  t ->
  (Ketrew_pure.Target.t list,
   [>  `Database of Trakeva.Error.t
   | `Database_unavailable of bytes
   | `Missing_data of string
   | `Target of [> `Deserilization of string ] ])
    Deferred_result.t


val activate_target :
  t ->
  target:Target.t ->
  reason:[ `Dependency of Target.id | `User ] ->
  (unit,
   [> `Database of
        [> `Act of Trakeva.Action.t | `Load of string ] * string
   | `Database_unavailable of string ])
    Deferred_result.t


val fold_active_targets :
  t ->
  init:'a ->
  f:('a ->
     target:Target.t ->
     ('a,
      [> `Database of
           [> `Get of Trakeva.Key_in_collection.t
           | `Iter of string
           | `Load of string ] *
           string
      | `Missing_data of string
      | `Target of [> `Deserilization of string ] ]
      as 'combined_errors)
       Deferred_result.t) ->
  ('a, 'combined_errors) Deferred_result.t

val update_target :
  t ->
  Target.t ->
  (unit,
   [> `Database of
        [> `Act of Trakeva.Action.t | `Load of string ] * string
   | `Database_unavailable of string ])
    Deferred_result.t

module Killing_targets: sig

  val proceed_to_mass_killing :
    t ->
    (bool,
     [> `Database of
          [> `Act of Trakeva.Action.t
          | `Get of Trakeva.Key_in_collection.t
          | `Get_all of string
          | `Load of string ] *
          string
     | `Database_unavailable of string
     | `Missing_data of string
     | `Target of [> `Deserilization of string ] ])
      Deferred_result.t
  val add_target_ids_to_kill_list :
    t ->
    string list ->
    (unit,
     [> `Database of
          [> `Act of Trakeva.Action.t | `Load of string ] * string
     | `Database_unavailable of string ])
      Deferred_result.t
end

module Adding_targets: sig
  val register_targets_to_add :
    t ->
    Target.t list ->
    (unit,
     [> `Database of
          [> `Act of Trakeva.Action.t | `Load of string ] * string
     | `Database_unavailable of string ])
      Deferred_result.t
  val check_and_really_add_targets :
    t ->
    (bool,
     [> `Database of
          [> `Act of Trakeva.Action.t
          | `Get of Trakeva.Key_in_collection.t
          | `Get_all of string
          | `Load of string ] *
          string
     | `Database_unavailable of string
     | `Missing_data of string
     | `Target of [> `Deserilization of string ] ])
      Deferred_result.t
end

module Synchronize: sig
  val copy :
    string ->
    string ->
    (unit,
     [> `Database of Trakeva.Error.t
     | `Database_unavailable of bytes
     | `IO of
          [> `Read_file_exn of bytes * exn
          | `Write_file_exn of bytes * exn ]
     | `Missing_data of bytes
     | `Not_a_directory of bytes
     | `System of
          [> `File_info of bytes
          | `List_directory of bytes
          | `Make_directory of bytes ] *
          [> `Exn of exn | `Wrong_access_rights of int ]
     | `Target of [> `Deserilization of bytes ] ])
      Deferred_result.t
end
