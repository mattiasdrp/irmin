(*
 * Copyright (c) 2013-2019 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt.Infix
include Inode_intf

let src =
  Logs.Src.create "irmin.pack.i" ~doc:"inodes for the irmin-pack backend"

module Log = (val Logs.src_log src : Logs.LOG)

let rec drop n (l : 'a Seq.t) () =
  match l () with
  | l' when n = 0 -> l'
  | Nil -> Nil
  | Cons (_, l') -> drop (n - 1) l' ()

let take : type a. int -> a Seq.t -> a list =
  let rec aux acc n (l : a Seq.t) =
    if n = 0 then acc
    else
      match l () with Nil -> acc | Cons (x, l') -> aux (x :: acc) (n - 1) l'
  in
  fun n s -> List.rev (aux [] n s)

module Make_intermediate
    (Conf : Config.S)
    (H : Irmin.Hash.S)
    (Node : Irmin.Private.Node.S with type hash = H.t) =
struct
  module Node = struct
    include Node
    module H = Irmin.Hash.Typed (H) (Node)

    let hash = H.hash
  end

  module T = struct
    type hash = H.t [@@deriving irmin]
    type step = Node.step [@@deriving irmin]
    type metadata = Node.metadata [@@deriving irmin]

    let default = Node.default

    type value = Node.value

    let value_t = Node.value_t
    let pp_hash = Irmin.Type.(pp hash_t)
  end

  module StepMap = struct
    include Map.Make (struct
      type t = T.step

      let compare = Irmin.Type.(unstage (compare T.step_t))
    end)

    let of_list l = List.fold_left (fun acc (k, v) -> add k v acc) empty l

    let t a =
      let open Irmin.Type in
      map (list (pair T.step_t a)) of_list bindings
  end

  (* Binary representation, useful to compute hashes *)
  module Bin = struct
    open T

    type inode = { index : int; hash : H.t }
    type inodes = { seed : int; length : int; entries : inode list }
    type v = Values of (step * value) list | Inodes of inodes

    let inode : inode Irmin.Type.t =
      let open Irmin.Type in
      record "Bin.inode" (fun index hash -> { index; hash })
      |+ field "index" int (fun t -> t.index)
      |+ field "hash" H.t (fun (t : inode) -> t.hash)
      |> sealr

    let inodes : inodes Irmin.Type.t =
      let open Irmin.Type in
      record "Bin.inodes" (fun seed length entries -> { seed; length; entries })
      |+ field "seed" int (fun t -> t.seed)
      |+ field "length" int (fun t -> t.length)
      |+ field "entries" (list inode) (fun t -> t.entries)
      |> sealr

    let v_t : v Irmin.Type.t =
      let open Irmin.Type in
      variant "Bin.v" (fun values inodes -> function
        | Values l -> values l | Inodes i -> inodes i)
      |~ case1 "Values" (list (pair step_t value_t)) (fun t -> Values t)
      |~ case1 "Inodes" inodes (fun t -> Inodes t)
      |> sealv

    module V =
      Irmin.Hash.Typed
        (H)
        (struct
          type t = v

          let t = v_t
        end)

    type t = { hash : H.t Lazy.t; stable : bool; v : v }

    let pre_hash_v = Irmin.Type.(unstage (pre_hash v_t))

    let t : t Irmin.Type.t =
      let open Irmin.Type in
      let pre_hash = stage (fun x -> pre_hash_v x.v) in
      record "Bin.t" (fun hash stable v -> { hash = lazy hash; stable; v })
      |+ field "hash" H.t (fun t -> Lazy.force t.hash)
      |+ field "stable" bool (fun t -> t.stable)
      |+ field "v" v_t (fun t -> t.v)
      |> sealr
      |> like ~pre_hash

    let node ~hash v = { stable = true; hash; v }
    let inode ~hash v = { stable = false; hash; v }
    let hash t = Lazy.force t.hash
  end

  (* Compressed binary representation *)
  module Compress = struct
    open T

    type name = Indirect of int | Direct of step
    type address = Indirect of int64 | Direct of H.t

    let address : address Irmin.Type.t =
      let open Irmin.Type in
      variant "Compress.address" (fun i d -> function
        | Indirect x -> i x | Direct x -> d x)
      |~ case1 "Indirect" int64 (fun x -> Indirect x)
      |~ case1 "Direct" H.t (fun x -> Direct x)
      |> sealv

    type inode = { index : int; hash : address }

    let inode : inode Irmin.Type.t =
      let open Irmin.Type in
      record "Compress.inode" (fun index hash -> { index; hash })
      |+ field "index" int (fun t -> t.index)
      |+ field "hash" address (fun t -> t.hash)
      |> sealr

    type inodes = { seed : int; length : int; entries : inode list }

    let inodes : inodes Irmin.Type.t =
      let open Irmin.Type in
      record "Compress.inodes" (fun seed length entries ->
          { seed; length; entries })
      |+ field "seed" int (fun t -> t.seed)
      |+ field "length" int (fun t -> t.length)
      |+ field "entries" (list inode) (fun t -> t.entries)
      |> sealr

    type value =
      | Contents of name * address * metadata
      | Node of name * address

    let is_default = Irmin.Type.(unstage (equal T.metadata_t)) T.default

    let value : value Irmin.Type.t =
      let open Irmin.Type in
      variant "Compress.value"
        (fun
          contents_ii
          contents_x_ii
          node_ii
          contents_id
          contents_x_id
          node_id
          contents_di
          contents_x_di
          node_di
          contents_dd
          contents_x_dd
          node_dd
        -> function
        | Contents (Indirect n, Indirect h, m) ->
            if is_default m then contents_ii (n, h) else contents_x_ii (n, h, m)
        | Node (Indirect n, Indirect h) -> node_ii (n, h)
        | Contents (Indirect n, Direct h, m) ->
            if is_default m then contents_id (n, h) else contents_x_id (n, h, m)
        | Node (Indirect n, Direct h) -> node_id (n, h)
        | Contents (Direct n, Indirect h, m) ->
            if is_default m then contents_di (n, h) else contents_x_di (n, h, m)
        | Node (Direct n, Indirect h) -> node_di (n, h)
        | Contents (Direct n, Direct h, m) ->
            if is_default m then contents_dd (n, h) else contents_x_dd (n, h, m)
        | Node (Direct n, Direct h) -> node_dd (n, h))
      |~ case1 "contents-ii" (pair int int64) (fun (n, i) ->
             Contents (Indirect n, Indirect i, T.default))
      |~ case1 "contents-x-ii" (triple int int64 metadata_t) (fun (n, i, m) ->
             Contents (Indirect n, Indirect i, m))
      |~ case1 "node-ii" (pair int int64) (fun (n, i) ->
             Node (Indirect n, Indirect i))
      |~ case1 "contents-id" (pair int H.t) (fun (n, h) ->
             Contents (Indirect n, Direct h, T.default))
      |~ case1 "contents-x-id" (triple int H.t metadata_t) (fun (n, h, m) ->
             Contents (Indirect n, Direct h, m))
      |~ case1 "node-id" (pair int H.t) (fun (n, h) ->
             Node (Indirect n, Direct h))
      |~ case1 "contents-di" (pair step_t int64) (fun (n, i) ->
             Contents (Direct n, Indirect i, T.default))
      |~ case1 "contents-x-di" (triple step_t int64 metadata_t)
           (fun (n, i, m) -> Contents (Direct n, Indirect i, m))
      |~ case1 "node-di" (pair step_t int64) (fun (n, i) ->
             Node (Direct n, Indirect i))
      |~ case1 "contents-dd" (pair step_t H.t) (fun (n, i) ->
             Contents (Direct n, Direct i, T.default))
      |~ case1 "contents-x-dd" (triple step_t H.t metadata_t) (fun (n, i, m) ->
             Contents (Direct n, Direct i, m))
      |~ case1 "node-dd" (pair step_t H.t) (fun (n, i) ->
             Node (Direct n, Direct i))
      |> sealv

    type v = Values of value list | Inodes of inodes

    let v_t : v Irmin.Type.t =
      let open Irmin.Type in
      variant "Compress.v" (fun values inodes -> function
        | Values x -> values x | Inodes x -> inodes x)
      |~ case1 "Values" (list value) (fun x -> Values x)
      |~ case1 "Inodes" inodes (fun x -> Inodes x)
      |> sealv

    type t = { hash : H.t; stable : bool; v : v }

    let node ~hash v = { hash; stable = true; v }
    let inode ~hash v = { hash; stable = false; v }
    let magic_node = 'N'
    let magic_inode = 'I'

    let stable : bool Irmin.Type.t =
      Irmin.Type.(map char)
        (fun n -> n = magic_node)
        (function true -> magic_node | false -> magic_inode)

    let t =
      let open Irmin.Type in
      record "Compress.t" (fun hash stable v -> { hash; stable; v })
      |+ field "hash" H.t (fun t -> t.hash)
      |+ field "stable" stable (fun t -> t.stable)
      |+ field "v" v_t (fun t -> t.v)
      |> sealr
  end

  module Val_impl = struct
    open T

    let equal_hash = Irmin.Type.(unstage (equal hash_t))
    let equal_value = Irmin.Type.(unstage (equal value_t))

    type inode = { i_hash : hash Lazy.t; mutable tree : t option }

    and entry = Empty | Inode of inode

    and inodes = { seed : int; length : int; entries : entry array }

    and v = Values of value StepMap.t | Inodes of inodes

    and t = { hash : hash Lazy.t; stable : bool; v : v }

    let pred t =
      match t.v with
      | Inodes i ->
          Array.fold_left
            (fun acc -> function
              | Empty -> acc
              | Inode i -> `Inode (Lazy.force i.i_hash) :: acc)
            [] i.entries
      | Values l ->
          StepMap.fold
            (fun _ v acc ->
              let v =
                match v with
                | `Node _ as k -> k
                | `Contents (k, _) -> `Contents k
              in
              v :: acc)
            l []

    let hash_of_inode (i : inode) = Lazy.force i.i_hash

    let inode_t t : inode Irmin.Type.t =
      let same_hash =
        Irmin.Type.stage @@ fun x y ->
        equal_hash (hash_of_inode x) (hash_of_inode y)
      in
      let open Irmin.Type in
      record "Node.inode" (fun hash tree -> { i_hash = lazy hash; tree })
      |+ field "hash" hash_t (fun t -> Lazy.force t.i_hash)
      |+ field "tree" (option t) (fun t -> t.tree)
      |> sealr
      |> like ~equal:same_hash

    let entry_t inode : entry Irmin.Type.t =
      let open Irmin.Type in
      variant "Node.entry" (fun empty inode -> function
        | Empty -> empty | Inode i -> inode i)
      |~ case0 "Empty" Empty
      |~ case1 "Inode" inode (fun i -> Inode i)
      |> sealv

    let inodes entry : inodes Irmin.Type.t =
      let open Irmin.Type in
      record "Node.entries" (fun seed length entries ->
          { seed; length; entries })
      |+ field "seed" int (fun t -> t.seed)
      |+ field "length" int (fun t -> t.length)
      |+ field "entries" (array entry) (fun t -> t.entries)
      |> sealr

    let length t =
      match t.v with Values vs -> StepMap.cardinal vs | Inodes vs -> vs.length

    let stable t = t.stable

    let get_tree ~find t =
      match t.tree with
      | Some t -> t
      | None -> (
          let h = hash_of_inode t in
          match find h with
          | None -> Fmt.failwith "%a: unknown key" pp_hash h
          | Some x ->
              t.tree <- Some x;
              x)

    type acc = {
      cursor : int;
      values : (step * value) list list;
      remaining : int;
    }

    let empty_acc n = { cursor = 0; values = []; remaining = n }

    let rec list_entry ~offset ~length ~find acc = function
      | Empty -> acc
      | Inode i -> list_values ~offset ~length ~find acc (get_tree ~find i)

    and list_inodes ~offset ~length ~find acc t =
      if acc.remaining <= 0 || offset + length <= acc.cursor then acc
      else if acc.cursor + t.length < offset then
        { acc with cursor = t.length + acc.cursor }
      else Array.fold_left (list_entry ~offset ~length ~find) acc t.entries

    and list_values ~offset ~length ~find acc t =
      if acc.remaining <= 0 || offset + length <= acc.cursor then acc
      else
        match t.v with
        | Values vs ->
            let len = StepMap.cardinal vs in
            if acc.cursor + len < offset then
              { acc with cursor = len + acc.cursor }
            else
              let to_drop =
                if acc.cursor > offset then 0 else offset - acc.cursor
              in
              let vs =
                StepMap.to_seq vs |> drop to_drop |> take acc.remaining
              in
              let n = List.length vs in
              {
                values = vs :: acc.values;
                cursor = acc.cursor + len;
                remaining = acc.remaining - n;
              }
        | Inodes t -> list_inodes ~offset ~length ~find acc t

    let list ?(offset = 0) ?length ~find t =
      let length =
        match length with
        | Some n -> n
        | None -> (
            match t.v with
            | Values vs -> StepMap.cardinal vs - offset
            | Inodes i -> i.length - offset)
      in
      let entries = list_values ~offset ~length ~find (empty_acc length) t in
      List.concat (List.rev entries.values)

    let to_bin_v = function
      | Values vs ->
          let vs = StepMap.bindings vs in
          Bin.Values vs
      | Inodes t ->
          let _, entries =
            Array.fold_left
              (fun (i, acc) -> function
                | Empty -> (i + 1, acc)
                | Inode inode ->
                    let hash = hash_of_inode inode in
                    (i + 1, { Bin.index = i; hash } :: acc))
              (0, []) t.entries
          in
          let entries = List.rev entries in
          Bin.Inodes { seed = t.seed; length = t.length; entries }

    let to_bin t =
      let v = to_bin_v t.v in
      if t.stable then Bin.node ~hash:t.hash v else Bin.inode ~hash:t.hash v

    let hash t = Lazy.force t.hash

    let stabilize ~find t =
      if t.stable then t
      else
        let n = length t in
        if n > Conf.stable_hash then t
        else
          let hash =
            lazy
              (let vs = list ~find t in
               Node.hash (Node.v vs))
          in
          { hash; stable = true; v = t.v }

    let hash_key = Irmin.Type.(unstage (short_hash step_t))
    let index ~seed k = abs (hash_key ~seed k) mod Conf.entries
    let inode ?tree i_hash = Inode { tree; i_hash }

    let of_bin t =
      let v =
        match t.Bin.v with
        | Bin.Values vs ->
            let vs = StepMap.of_list vs in
            Values vs
        | Inodes t ->
            let entries = Array.make Conf.entries Empty in
            List.iter
              (fun { Bin.index; hash } -> entries.(index) <- inode (lazy hash))
              t.entries;
            Inodes { seed = t.Bin.seed; length = t.length; entries }
      in
      { hash = t.Bin.hash; stable = t.Bin.stable; v }

    let pre_hash_bin = Irmin.Type.(unstage (pre_hash Bin.v_t))

    let v_t t : v Irmin.Type.t =
      let open Irmin.Type in
      let pre_hash = stage (fun x -> pre_hash_bin (to_bin_v x)) in
      let entry = entry_t (inode_t t) in
      variant "Inode.t" (fun values inodes -> function
        | Values v -> values v | Inodes i -> inodes i)
      |~ case1 "Values" (StepMap.t value_t) (fun t -> Values t)
      |~ case1 "Inodes" (inodes entry) (fun t -> Inodes t)
      |> sealv
      |> like ~pre_hash

    let t : t Irmin.Type.t =
      let open Irmin.Type in
      mu @@ fun t ->
      let v = v_t t in
      let t =
        record "hash" (fun hash stable v -> { hash = lazy hash; stable; v })
        |+ field "hash" H.t (fun t -> Lazy.force t.hash)
        |+ field "stable" bool (fun t -> t.stable)
        |+ field "v" v (fun t -> t.v)
        |> sealr
      in
      let pre_hash = Irmin.Type.unstage (Irmin.Type.pre_hash v) in
      like ~pre_hash:(stage @@ fun x -> pre_hash x.v) t

    let empty =
      let hash = lazy (Node.hash Node.empty) in
      { stable = true; hash; v = Values StepMap.empty }

    let values vs =
      let length = StepMap.cardinal vs in
      if length = 0 then empty
      else
        let v = Values vs in
        let hash = lazy (Bin.V.hash (to_bin_v v)) in
        { hash; stable = false; v }

    let inodes is =
      let v = Inodes is in
      let hash = lazy (Bin.V.hash (to_bin_v v)) in
      { hash; stable = false; v }

    let of_values l = values (StepMap.of_list l)

    let is_empty t =
      match t.v with Values vs -> StepMap.is_empty vs | Inodes _ -> false

    let find_value ~seed ~find t s =
      let rec aux ~seed = function
        | Values vs -> ( try Some (StepMap.find s vs) with Not_found -> None)
        | Inodes t -> (
            let i = index ~seed s in
            let x = t.entries.(i) in
            match x with
            | Empty -> None
            | Inode i -> aux ~seed:(seed + 1) (get_tree ~find i).v)
      in
      aux ~seed t.v

    let find ~find t s = find_value ~seed:0 ~find t s

    let rec add ~seed ~find ~copy ~replace t s v k =
      match t.v with
      | Values vs ->
          let length =
            if replace then StepMap.cardinal vs else StepMap.cardinal vs + 1
          in
          let t =
            if length <= Conf.entries then values (StepMap.add s v vs)
            else
              let vs = StepMap.bindings (StepMap.add s v vs) in
              let empty =
                inodes
                  { length = 0; seed; entries = Array.make Conf.entries Empty }
              in
              let aux t (s, v) =
                (add [@tailcall]) ~seed ~find ~copy:false ~replace t s v
                  (fun x -> x)
              in
              List.fold_left aux empty vs
          in
          k t
      | Inodes t -> (
          let length = if replace then t.length else t.length + 1 in
          let entries = if copy then Array.copy t.entries else t.entries in
          let i = index ~seed s in
          match entries.(i) with
          | Empty ->
              let tree = values (StepMap.singleton s v) in
              entries.(i) <- inode ~tree tree.hash;
              let t = inodes { seed; length; entries } in
              k t
          | Inode n ->
              let t = get_tree ~find n in
              add ~seed:(seed + 1) ~find ~copy ~replace t s v @@ fun tree ->
              entries.(i) <- inode ~tree tree.hash;
              let t = inodes { seed; length; entries } in
              k t)

    let add ~find ~copy t s v =
      (* XXX: [find_value ~seed:42] should break the unit tests. It doesn't. *)
      match find_value ~seed:0 ~find t s with
      | Some v' when equal_value v v' -> stabilize ~find t
      | Some _ -> add ~seed:0 ~find ~copy ~replace:true t s v (stabilize ~find)
      | None -> add ~seed:0 ~find ~copy ~replace:false t s v (stabilize ~find)

    let rec remove ~seed ~find t s k =
      match t.v with
      | Values vs ->
          let t = values (StepMap.remove s vs) in
          k t
      | Inodes t -> (
          let length = t.length - 1 in
          if length <= Conf.entries then
            let vs =
              list_inodes ~offset:0 ~length:t.length ~find (empty_acc t.length)
                t
            in
            let vs = List.concat (List.rev vs.values) in
            let vs = StepMap.of_list vs in
            let vs = StepMap.remove s vs in
            let t = values vs in
            k t
          else
            let entries = Array.copy t.entries in
            let i = index ~seed s in
            match entries.(i) with
            | Empty -> assert false
            | Inode t ->
                let t = get_tree ~find t in
                remove ~seed:(seed + 1) ~find t s @@ fun tree ->
                entries.(i) <- inode ~tree (lazy (hash tree));
                let t = inodes { seed; length; entries } in
                k t)

    let remove ~find t s =
      (* XXX: [find_value ~seed:42] should break the unit tests. It doesn't. *)
      match find_value ~seed:0 ~find t s with
      | None -> stabilize ~find t
      | Some _ -> remove ~find ~seed:0 t s (stabilize ~find)

    let v l : t =
      let len = List.length l in
      let find _ = assert false in
      let t =
        if len <= Conf.entries then of_values l
        else
          let aux acc (s, v) = add ~find ~copy:false acc s v in
          List.fold_left aux empty l
      in
      stabilize ~find t

    let add ~find t s v = add ~find ~copy:true t s v

    let save ~add ~mem t =
      let rec aux ~seed t =
        Log.debug (fun l -> l "save seed:%d" seed);
        match t.v with
        | Values _ -> add (Lazy.force t.hash) (to_bin t)
        | Inodes n ->
            Array.iter
              (function
                | Empty | Inode { tree = None; _ } -> ()
                | Inode ({ tree = Some t; _ } as i) ->
                    let hash = hash_of_inode i in
                    if mem hash then () else aux ~seed:(seed + 1) t)
              n.entries;
            add (Lazy.force t.hash) (to_bin t)
      in
      aux ~seed:0 t
  end

  module Elt = struct
    type t = Bin.t

    let t = Bin.t

    let magic (t : t) =
      if t.stable then Compress.magic_node else Compress.magic_inode

    let hash t = Bin.hash t
    let step_to_bin = Irmin.Type.(unstage (to_bin_string T.step_t))
    let step_of_bin = Irmin.Type.(unstage (of_bin_string T.step_t))
    let encode_compress = Irmin.Type.(unstage (encode_bin Compress.t))
    let decode_compress = Irmin.Type.(unstage (decode_bin Compress.t))

    let encode_bin ~dict ~offset (t : t) k =
      let step s : Compress.name =
        let str = step_to_bin s in
        if String.length str <= 3 then Direct s
        else match dict str with Some i -> Indirect i | None -> Direct s
      in
      let hash h : Compress.address =
        match offset h with
        | None -> Compress.Direct h
        | Some off -> Compress.Indirect off
      in
      let inode : Bin.inode -> Compress.inode =
       fun n ->
        let hash = hash n.hash in
        { index = n.index; hash }
      in
      let value : T.step * T.value -> Compress.value = function
        | s, `Contents (c, m) ->
            let s = step s in
            let v = hash c in
            Compress.Contents (s, v, m)
        | s, `Node n ->
            let s = step s in
            let v = hash n in
            Compress.Node (s, v)
      in
      (* List.map is fine here as the number of entries is small *)
      let v : Bin.v -> Compress.v = function
        | Values vs -> Values (List.map value vs)
        | Inodes { seed; length; entries } ->
            let entries = List.map inode entries in
            Inodes { Compress.seed; length; entries }
      in
      let t =
        if t.stable then Compress.node ~hash:k (v t.v)
        else Compress.inode ~hash:k (v t.v)
      in
      encode_compress t

    exception Exit of [ `Msg of string ]

    let decode_bin_with_offset ~dict ~hash t off : int * t =
      let off, i = decode_compress t off in
      let step : Compress.name -> T.step = function
        | Direct n -> n
        | Indirect s -> (
            match dict s with
            | None -> raise_notrace (Exit (`Msg "dict"))
            | Some s -> (
                match step_of_bin s with
                | Error e -> raise_notrace (Exit e)
                | Ok v -> v))
      in
      let hash : Compress.address -> H.t = function
        | Indirect off -> hash off
        | Direct n -> n
      in
      let inode : Compress.inode -> Bin.inode =
       fun n ->
        let hash = hash n.hash in
        { index = n.index; hash }
      in
      let value : Compress.value -> T.step * T.value = function
        | Contents (n, h, metadata) ->
            let name = step n in
            let node = hash h in
            (name, `Contents (node, metadata))
        | Node (n, h) ->
            let name = step n in
            let node = hash h in
            (name, `Node node)
      in
      let t : Compress.v -> Bin.v = function
        | Values vs -> Values (List.rev_map value (List.rev vs))
        | Inodes { seed; length; entries } ->
            let entries = List.map inode entries in
            Inodes { seed; length; entries }
      in
      let t =
        if i.stable then Bin.node ~hash:(lazy i.hash) (t i.v)
        else Bin.inode ~hash:(lazy i.hash) (t i.v)
      in
      (off, t)

    let decode_bin ~dict ~hash t off =
      decode_bin_with_offset ~dict ~hash t off |> snd
  end

  type hash = T.hash

  let pp_hash = T.pp_hash

  let decode_bin ~dict ~hash t off =
    Elt.decode_bin_with_offset ~dict ~hash t off

  module Val = struct
    include T
    module I = Val_impl

    type t = { find : H.t -> I.t option; v : I.t }

    let pred t = I.pred t.v
    let niet _ = assert false

    let v l =
      let v = I.v l in
      { find = niet; v }

    let list ?offset ?length t = I.list ~find:t.find ?offset ?length t.v
    let empty = { find = niet; v = I.empty }
    let is_empty t = I.is_empty t.v
    let find t s = I.find ~find:t.find t.v s

    let add t s v =
      let v = I.add ~find:t.find t.v s v in
      if v == t.v then t else { t with v }

    let remove t s =
      let v = I.remove ~find:t.find t.v s in
      if v == t.v then t else { t with v }

    let pre_hash_i = Irmin.Type.(unstage (pre_hash I.t))
    let pre_hash_node = Irmin.Type.(unstage (pre_hash Node.t))

    let t : t Irmin.Type.t =
      let pre_hash =
        Irmin.Type.stage @@ fun x ->
        if not x.v.stable then pre_hash_i x.v
        else
          let vs = list x in
          pre_hash_node (Node.v vs)
      in
      Irmin.Type.map I.t ~pre_hash (fun v -> { find = niet; v }) (fun t -> t.v)

    module Private = struct
      let hash t = I.hash t.v
      let stable t = I.stable t.v
      let length t = I.length t.v

      type sexp = Sexplib.Sexp.t
      (* type inode = { i_hash : hash Lazy.t; mutable tree : t option }
       * and entry = Empty | Inode of inode
       * and inodes = { seed : int; length : int; entries : entry array }
       * and v = Values of value StepMap.t | Inodes of inodes
       * and t = { hash : hash Lazy.t; stable : bool; v : v } *)
      let parse_from_string s =
        let lexbuf = Lexing.from_string s in
        Sexplib.Sexp.scan_sexp lexbuf

      let parse_from_file f = Sexplib.Sexp.load_sexp f

      let sexp_of_hash h =
        Sexplib.Sexp.(Atom (Fmt.str "%a" pp_hash h))

      let sexp_of_ihash h =
        Sexplib.Sexp.(List [
            Atom "i_hash";
            Sexplib__Std.sexp_of_lazy_t sexp_of_hash h
          ]
          )

      let sexp_of_metadata m =
        Sexplib.Sexp.(Atom (Fmt.str "%a" (Irmin.Type.pp metadata_t) m))

      let sexp_of_kind k =
        let open Sexplib.Sexp in
        match k with
        | `Contents (h, m) ->
          List [
            Atom "B";
            (* List [
             *   Atom "hash"; *)
            sexp_of_hash h;
            (* ]; *)
            (* List [
             *   Atom "metadata"; *)
              sexp_of_metadata m
            (* ] *)
          ]
        | `Node h ->
          List [
            Atom "N";
            sexp_of_hash h
          ]

      let sexp_of_step s =
        Sexplib.Sexp.((* List [
             * Atom "step"; *)
            Atom (Fmt.str "%a" (Irmin.Type.pp step_t) s)
          (* ] *)
          )

      let sexp_of_seed s =
        Sexplib.Sexp.(
          List [
            Atom "seed";
            Sexplib__Std.sexp_of_int s
          ]
        )

      let sexp_of_length l =
        Sexplib.Sexp.(
          List [
            Atom "length";
            Sexplib__Std.sexp_of_int l
          ]
        )

      let rec sexp_of_tree t =
        (* Sexplib.Sexp.List [
         *   Sexplib.Sexp.Atom "tree"; *)
          match t with
          | None -> Sexplib.Sexp.Atom "None"
          | Some t -> sexp_of_t t
        (* ]                        *)

      and sexp_of_inode i =
        (* Sexplib.Sexp.( *)
          (* List [ *)
            (* sexp_of_ihash i.I.i_hash; *)
            sexp_of_tree i.I.tree
          (* ] *)
          (* ) *)

      and sexp_of_entry e =
        match e with
        | I.Empty -> Sexplib.Sexp.Atom "E" (* Sexplib.Sexp.List [] *)
        | I.Inode i -> sexp_of_inode i

      and sexp_of_entries a =
        Sexplib.Sexp.List (
          List.rev @@
          Array.fold_left (fun acc e -> sexp_of_entry e :: acc) [] a
        )

      and sexp_of_inodes i =
        let open Sexplib.Sexp in
        (* List [ *)
          (* sexp_of_seed i.I.seed; *)
          (* sexp_of_length i.I.length; *)
          sexp_of_entries i.I.entries
        (* ] *)

      and sexp_of_stepmap vs =
        let open Sexplib.Sexp in
        List (
          StepMap.fold (fun s k acc ->
              List [
                sexp_of_step s;
                sexp_of_kind k
              ]
                :: acc
            ) vs []
        )

      and sexp_of_v v =
        let open Sexplib.Sexp in
        match v with
        | I.Values vs ->
          List [
            Atom "V";
            sexp_of_stepmap vs
          ]
        | Inodes i ->
          List [
            Atom "I";
            sexp_of_inodes i
          ]

      and sexp_of_t t =
        Sexplib.Sexp.(
          List [
            (* List [ *)
              (* Atom "hash"; *)
            Sexplib__Std.sexp_of_lazy_t sexp_of_hash t.hash;
            (* ]; *)
            (* List [
             *   Atom "stable";
             *   Sexplib__Std.sexp_of_bool t.stable
             * ]; *)
            (* List [
             *   Atom "v"; *)
              sexp_of_v t.v
            (* ] *)
          ]
        )

      let sexp_of_t t = sexp_of_t t.v

      exception Misconstructed_Sexp of string

      (* let stepmap_of_sexp ss =
       *   let open Sexplib.Sexp in
       *   match ss with
       *   | List l ->
       *     List.fold_left (fun acc sk ->
       *         let s, k =
       *           match sk with
       *           | List [ List [ Atom "step"; Atom st ];
       *                    List [ Atom k; Atom sk ] ] ->
       *             match k with
       *             | "contents" ->  *)

      let v_of_sexp _vs = I.Values StepMap.empty
        (* let open Sexplib.Sexp in
         * match vs with
         * | List [ Atom "values"; s ] -> I.Values (stepmap_of_sexp s)
         * | List [ Atom "inodes"; s ] -> I.Inodes (inodes_of_sexp s)
         * | _ -> raise (Misconstructed_Sexp (to_string vs)) *)

      let t_of_sexp ts =
        let open Sexplib.Sexp in
        let open I in
        match ts with
        | Atom s -> raise (Misconstructed_Sexp s)
        | List [ List [ Atom "hash"; Atom h ];
                 List [ Atom "stable"; Atom s ];
                 List [ Atom "v"; sv ]
               ] -> {hash = lazy (Result.get_ok (Irmin.Type.of_string hash_t h));
                     stable = bool_of_string s;
                     v = v_of_sexp sv}
        | _ -> raise (Misconstructed_Sexp (to_string ts))

      let t_of_sexp s = {find = niet; v = t_of_sexp s}
    end
  end
end

module Make_ext
    (H : Irmin.Hash.S)
    (Node : Irmin.Private.Node.S with type hash = H.t)
    (Inter : INTER
               with type hash = H.t
                and type Val.metadata = Node.metadata
                and type Val.step = Node.step)
    (Pack : Pack.S with type value = Inter.Elt.t and type key = H.t) =
struct
  module Key = H

  type 'a t = 'a Pack.t
  type key = Key.t
  type value = Inter.Val.t

  let mem t k = Pack.mem t k

  let unsafe_find ~check_integrity t k =
    match Pack.unsafe_find ~check_integrity t k with
    | None -> None
    | Some v ->
        let v = Inter.Val_impl.of_bin v in
        Some v

  let find t k =
    Pack.find t k >|= function
    | None -> None
    | Some v ->
        let v = Inter.Val_impl.of_bin v in
        let find = unsafe_find ~check_integrity:true t in
        Some { Inter.Val.find; v }

  let save t v =
    let add k v =
      Pack.unsafe_append ~ensure_unique:true ~overcommit:false t k v
    in
    Inter.Val_impl.save ~add ~mem:(Pack.unsafe_mem t) v

  let hash v = Inter.Val_impl.hash v.Inter.Val.v

  let add t v =
    save t v.Inter.Val.v;
    Lwt.return (hash v)

  let equal_hash = Irmin.Type.(unstage (equal H.t))

  let check_hash expected got =
    if equal_hash expected got then ()
    else
      Fmt.invalid_arg "corrupted value: got %a, expecting %a" Inter.pp_hash
        expected Inter.pp_hash got

  let unsafe_add t k v =
    check_hash k (hash v);
    save t v.Inter.Val.v;
    Lwt.return_unit

  let batch = Pack.batch
  let v = Pack.v
  let integrity_check = Pack.integrity_check
  let close = Pack.close
  let sync = Pack.sync
  let clear = Pack.clear
  let clear_caches = Pack.clear_caches

  let decode_bin ~dict ~hash buff off =
    Inter.decode_bin ~dict ~hash buff off |> fst
end

module Make
    (Conf : Config.S)
    (H : Irmin.Hash.S)
    (Pack : Pack.MAKER with type key = H.t)
    (Node : Irmin.Private.Node.S with type hash = H.t) =
struct
  type index = Pack.index

  module Inter = Make_intermediate (Conf) (H) (Node)
  module Pack = Pack.Make (Inter.Elt)
  module Val = Inter.Val
  include Make_ext (H) (Node) (Inter) (Pack)
end
