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

module type DICT = sig
  type t

  val find : t -> int -> string option

  val index : t -> string -> int option

  val flush : t -> unit

  val sync : t -> unit

  val v :
    ?version:[ `V1 | `V2 ] ->
    ?fresh:bool ->
    ?readonly:bool ->
    ?capacity:int ->
    string ->
    t

  val clear : t -> unit

  val close : t -> unit

  val valid : t -> bool

  val version : t -> [ `V1 | `V2 ]

  val generation : t -> int64
end

module type ATOMIC_WRITE_STORE = sig
  include Irmin.ATOMIC_WRITE_STORE

  val v :
    ?version:[ `V1 | `V2 ] -> ?fresh:bool -> ?readonly:bool -> string -> t Lwt.t

  val version : t -> [ `V1 | `V2 ]

  val generation : t -> int64
end

module type CONTENT_ADDRESSABLE_STORE = sig
  include Irmin.CONTENT_ADDRESSABLE_STORE

  type index

  val v :
    ?version:[ `V1 | `V2 ] ->
    ?fresh:bool ->
    ?readonly:bool ->
    ?lru_size:int ->
    index:index ->
    string ->
    [ `Read ] t Lwt.t

  val batch : [ `Read ] t -> ([ `Read | `Write ] t -> 'a Lwt.t) -> 'a Lwt.t

  val unsafe_append : 'a t -> key -> value -> unit

  val unsafe_mem : 'a t -> key -> bool

  val unsafe_find : 'a t -> key -> value option

  val flush : ?index:bool -> 'a t -> unit

  val sync : 'a t -> unit

  val clear : 'a t -> unit

  type integrity_error = [ `Wrong_hash | `Absent_value ]

  val integrity_check :
    offset:int64 -> length:int -> key -> 'a t -> (unit, integrity_error) result

  val close : 'a t -> unit Lwt.t

  val version : 'a t -> [ `V1 | `V2 ]

  val generation : 'a t -> int64
end
