(*
 * Copyright (c) 2018-2021 Tarides <contact@tarides.com>
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

module type S = sig
  type t

  val find : t -> int -> string option
  val index : t -> string -> int option
  val flush : t -> unit

  val sync : t -> unit
  (** syncs a readonly dict with the file on disk. *)

  val v : ?fresh:bool -> ?readonly:bool -> ?capacity:int -> string -> t
  val truncate : t -> unit
  val close : t -> unit
  val valid : t -> bool
end

module type Sigs = sig
  module type S = S

  module Make (_ : IO.S) : S
end
