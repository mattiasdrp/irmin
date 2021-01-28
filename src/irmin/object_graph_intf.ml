module type S = sig
  include Graph.Sig.I
  (** Directed graph *)

  include Graph.Oper.S with type g := t
  (** Basic operations. *)

  (** Topological traversal *)
  module Topological : sig
    val fold : (vertex -> 'a -> 'a) -> t -> 'a -> 'a
  end

  val vertex : t -> vertex list
  (** Get all the vertices. *)

  val edges : t -> (vertex * vertex) list
  (** Get all the relations. *)

  val closure :
    ?depth:int ->
    pred:(vertex -> vertex list Lwt.t) ->
    min:vertex list ->
    max:vertex list ->
    unit ->
    t Lwt.t
  (** [closure depth pred min max ()] creates the transitive closure graph of
      [max] using the predecessor relation [pred]. The graph is bounded by the
      [min] nodes and by [depth].

      {b Note:} Both [min] and [max] are subsets of [n]. *)

  val iter :
    ?cache_size:int ->
    ?depth:int ->
    pred:(vertex -> vertex list Lwt.t) ->
    min:vertex list ->
    max:vertex list ->
    node:(vertex -> unit Lwt.t) ->
    ?edge:(vertex -> vertex -> unit Lwt.t) ->
    skip:(vertex -> bool Lwt.t) ->
    rev:bool ->
    unit ->
    unit Lwt.t
  (** [iter depth min max node edge skip rev ()] iterates in topological order
      over the closure graph starting with the [max] nodes and bounded by the
      [min] nodes and by [depth].

      It applies three functions while traversing the graph: [node] on the
      nodes; [edge n predecessor_of_n] on the directed edges and [skip n] to not
      include a node [n], its predecessors and the outgoing edges of [n].

      If [rev] is true (the default) then the graph is traversed in the reverse
      order: [node n] is applied only after it was applied on all its
      predecessors; [edge n p] is applied after [node n]. Note that [edge n p]
      is applied even if [p] is skipped.

      [cache_size] is the size of the LRU cache used to store nodes already
      seen. If [None] (by default) every traversed nodes is stored (and thus no
      entries are never removed from the LRU). *)

  val output :
    Format.formatter ->
    (vertex * Graph.Graphviz.DotAttributes.vertex list) list ->
    (vertex * Graph.Graphviz.DotAttributes.edge list * vertex) list ->
    string ->
    unit
  (** [output ppf vertex edges name] create aand dumps the graph contents on
      [ppf]. The graph is defined by its [vertex] and [edges]. [name] is the
      name of the output graph.*)

  val min : t -> vertex list
  (** Compute the minimum vertex. *)

  val max : t -> vertex list
  (** Compute the maximun vertex. *)

  type dump = vertex list * (vertex * vertex) list
  (** Expose the graph internals. *)

  val export : t -> dump
  (** Expose the graph as a pair of vertices and edges. *)

  val import : dump -> t
  (** Import a graph. *)

  module Dump : Type.S with type t = dump
  (** The base functions over graph internals. *)
end

module type HASH = sig
  include Type.S

  val short_hash : t -> int
end

module type Object_graph = sig
  module type S = S
  module type HASH = HASH

  (** Build a graph. *)
  module Make (Hash : HASH) (Branch : Type.S) :
    S
      with type V.t =
            [ `Contents of Hash.t
            | `Node of Hash.t
            | `Commit of Hash.t
            | `Branch of Branch.t ]
end