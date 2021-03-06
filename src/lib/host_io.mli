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

(** Definition of a host; a place to run commands or handle files. *)
open Ketrew_pure.Internal_pervasives
open Unix_io



(** Helper functions to build SSH commands. *)
module Ssh : sig
  val scp_push: Ketrew_pure.Host.Ssh.t -> src:string list -> dest:string -> string list
  (** Generate an SCP command for the given host with the destination
      directory or file path. *)

  val scp_pull: Ketrew_pure.Host.Ssh.t -> src:string list -> dest:string -> string list
  (** Generate an SCP command for the given host as source. *)

end


module Error: sig

  type 'a execution = 'a constraint 'a = [>
    | `Unix_exec of string
    | `Execution of
        <host : string; stdout: string option; stderr: string option; message: string>
    | `Ssh_failure of
        [> `Wrong_log of string
        | `Wrong_status of Unix_process.Exit_code.t ] * string 
    | `System of [> `Sleep of float ] * [> `Exn of exn ]
    | `Timeout of float
  ]

  type 'a non_zero_execution = 'a constraint 'a = 
    [> `Non_zero of (string * int) ] execution


  type classified = [
    | `Fatal of string
    | `Recoverable of string
  ]
  (** The “imposed” error types for “long-running” plugins.
      A [`Fatal _] error will make the target die with the error,
      whereas if an error is [`Recoverable _] Ketrew will keep trying
      (for example, a networking error which may not happen later).
  *)

  

  val classify :
    [ `Execution of
        < host : string; message : string; stderr : string option;
          stdout : string option >
    | `Non_zero of string * int
    | `System of [ `Sleep of float ] * [ `Exn of exn ]
    | `Timeout of float
    | `Ssh_failure of
        [> `Wrong_log of string
        | `Wrong_status of Unix_process.Exit_code.t ] *
        string
    | `Unix_exec of string ] ->
    [ `Execution | `Ssh | `Unix ]
  (**
     Get a glance at the gravity of the situation: {ul
     {li [`Unix]: a function of the kind {!Unix.exec} failed.}
     {li [`Ssh]: SSH failed to run something but it does not mean that the
     actual command is wrong.}
     {li [`Execution]: SSH/[Unix] succeeded but the command failed.}
     } *)

  val log :
    [< `Unix_exec of string
    | `Non_zero of (string * int)
    | `System of [< `Sleep of float ] * [< `Exn of exn ]
    | `Timeout of float
    | `Execution of
         < host : string; message : string; stderr : string option;
           stdout : string option; .. >
    | `Ssh_failure of
         [< `Wrong_log of string
         | `Wrong_status of Unix_process.Exit_code.t ] * string ] ->
    Log.t

end

type t = Ketrew_pure.Host.t

val default_timeout_upper_bound: float ref
(** Default (upper bound) of the `?timeout` arguments. *)

type timeout = [ 
  | `Host_default
  | `None
  | `Seconds of float
  | `At_most_seconds of float
]
(** Timeout specification for execution functions below.
    
    - [`Host_default] → use the [excution_timeout] value of the host.     
    - [`None] → force no timeout even if the host has a [execution_timeout].
    - [`Seconds f] → use [f] seconds as timeout.
    - [`At_most_seconds f] -> use [f] seconds, unless the host has a smaller
    [execution_timeout] field.

    The default value is [`At_most_seconds !default_timeout_upper_bound].

*)

val execute: ?timeout:timeout -> t -> string list ->
  (<stdout: string; stderr: string; exited: int>,
   [> `Host of _ Error.execution ]) Deferred_result.t
(** Generic execution which tries to behave like [Unix.execv] even
    on top of SSH. *)

type shell = string -> string list
(** A “shell” is a function that takes a command and returns, and
     execv-style string list; the default for each host
     is ["sh"; "-c"; cmd] *)

val shell_sh: sh:string -> shell
(** Call sh-style commands using the command argument (e.g. [shell_sh "/bin/sh"]
   for a known path or command). *)

val get_shell_command_output :
  ?timeout:timeout ->
  ?with_shell:shell ->
  t ->
  string ->
  (string * string, [> `Host of  _ Error.non_zero_execution]) Deferred_result.t
(** Run a shell command on the host, and return its [(stdout, stderr)] pair
    (succeeds {i iff } the exit status is [0]). *)

val get_shell_command_return_value :
  ?timeout:timeout ->
  ?with_shell:shell ->
  t ->
  string ->
  (int, [> `Host of _ Error.execution ]) Deferred_result.t
(** Run a shell command on the host, and return its exit status value. *)

val run_shell_command :
  ?timeout:timeout ->
  ?with_shell:shell ->
  t ->
  string ->
  (unit, [> `Host of  _ Error.non_zero_execution])  Deferred_result.t
(** Run a shell command on the host (succeeds {i iff } the exit status is [0]).
*)

val do_files_exist :
  ?timeout:timeout ->
  ?with_shell:shell ->
  t ->
  Ketrew_pure.Path.t list ->
  (bool, [> `Host of _ Error.execution ])
  Deferred_result.t
(** Check existence of a list of files/directories. *)

val get_fresh_playground :
  t -> Ketrew_pure.Path.t option
(** Get a new subdirectory in the host's playground *)

val ensure_directory :
  ?timeout:timeout ->
  ?with_shell:shell ->
  t ->
  path:Ketrew_pure.Path.t ->
  (unit, [> `Host of _ Error.non_zero_execution ]) Deferred_result.t
(** Make sure the directory [path] exists on the host. *)

val put_file :
  ?timeout:timeout ->
  t ->
  path: Ketrew_pure.Path.t ->
  content:string ->
  (unit,
   [> `Host of _ Error.execution
    | `IO of [> `Write_file_exn of IO.path * exn ] ])
  Deferred_result.t
(** Write a file on the host at [path] containing [contents]. *)

val get_file :
  ?timeout:timeout ->
  t ->
  path:Ketrew_pure.Path.t ->
  (string,
   [> `Cannot_read_file of string * string
    | `Timeout of Time.t ])
  Deferred_result.t
(** Read the file from the host at [path]. *)

val grab_file_or_log:
  ?timeout:timeout ->
  t -> 
  Ketrew_pure.Path.t ->
  (string, Log.t) Deferred_result.t
(** Weakly typed version of {!get_file}, it fails with a {!Log.t}
    (for use in “long-running” plugins).  *)
