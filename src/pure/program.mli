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

(** The “things” to run on a given host. *)

open Internal_pervasives


type t = [
  | `And of t list
  | `Exec of string list
  | `Shell_command of string
] [@@deriving yojson]
(** A program. *)

val to_shell_commands: t -> string list
(** Convert a program to a list of shell commands. *)

val to_single_shell_command: t -> string
(** Convert a program to a shell command. *)

val log: t -> Log.t
(** Create a {!Log.t} document to display a program. *)

val to_string_hum: t -> string
(** Get a display-friendly string of a program. *)

val markup: ?flatten: bool -> t -> Display_markup.t
