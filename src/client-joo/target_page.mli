
type t

val create:
  target_cache:Local_cache.Target_cache.t ->
  id:string ->
  restart_target:(on_result:([ `Error of string | `Ok of unit ] -> unit) -> unit) ->
  kill_target:(on_result:([ `Error of string | `Ok of unit ] -> unit) -> unit) ->
  target_link_on_click_handler:(id:string -> unit) ->
  reload_available_queries:(unit -> unit) ->
  reload_query_result:(query:string -> unit) ->
  available_queries:Local_cache.Target_cache.query_description
      Reactive.Signal.t ->
  get_query_result:(query:bytes ->
                    [ `Error of bytes
                    | `None
                    | `String of float * bytes ] Reactive.signal) ->
  t

val eq: t -> t -> bool
val target_id: t -> string

module Html: sig
  val title: t -> [> Html5_types.span ] Reactive_html5.H5.elt
  val render: t -> [> Html5_types.div ] Reactive_html5.H5.elt
end
