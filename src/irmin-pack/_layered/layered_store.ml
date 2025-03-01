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

open! Import

module type S = Irmin_pack.Pack_store.S

let stats = function
  | "Contents" -> Irmin_layers.Stats.copy_contents ()
  | "Node" -> Irmin_layers.Stats.copy_nodes ()
  | "Commit" -> Irmin_layers.Stats.copy_commits ()
  | _ -> failwith "unexpected type in stats"

module Copy
    (Key : Irmin.Key.S)
    (SRC : Irmin_pack.Indexable.S with type key = Key.t and type hash = Key.hash)
    (DST : Irmin_pack.Indexable.S
             with type key = Key.t
              and type hash = Key.hash
              and type value = SRC.value) =
struct
  let ignore_lwt _ = Lwt.return_unit

  let copy ~src ~dst str k =
    [%log.debug "copy %s %a" str (Irmin.Type.pp Key.t) k];
    match SRC.unsafe_find ~check_integrity:false src k with
    | None ->
        [%log.warn
          "Attempt to copy %s %a not contained in upper." str
            (Irmin.Type.pp Key.t) k]
    | Some v ->
        stats str;
        let (_ : Key.t) =
          DST.unsafe_append ~ensure_unique:false ~overcommit:true dst
            (Key.to_hash k) v
        in
        ()

  let check ~src ?(some = ignore_lwt) ?(none = ignore_lwt) k =
    SRC.find src k >>= function None -> none () | Some v -> some v
end

let pp_during_freeze ppf = function
  | true -> Fmt.string ppf " during freeze"
  | false -> ()

let pp_layer_id = Irmin_layers.Layer_id.pp
let pp_current_upper ppf t = pp_layer_id ppf (if t then `Upper1 else `Upper0)
let pp_next_upper ppf t = pp_layer_id ppf (if t then `Upper0 else `Upper1)

module Indexable
    (H : Irmin.Hash.S)
    (Index : Irmin_pack.Index.S)
    (U : S
           with type index := Index.t
            and type hash = H.t
            and type key = H.t Irmin_pack.Pack_key.t)
    (L : S
           with type index := Index.t
            and type hash = U.hash
            and type key = U.key
            and type value = U.value) =
struct
  type index = Index.t
  type hash = U.hash
  type key = U.key
  type value = U.value

  module Key = Irmin_pack.Pack_key.Make (H)

  type 'a t = {
    lower : read L.t option;
    mutable flip : bool;
    uppers : read U.t * read U.t;
    freeze_in_progress : unit -> bool;
    mutable newies : key list;
  }

  module U = U
  module L = L

  let v upper1 upper0 lower ~flip ~freeze_in_progress =
    [%log.debug "v flip = %b" flip];
    { lower; flip; uppers = (upper1, upper0); freeze_in_progress; newies = [] }

  let next_upper t = if t.flip then snd t.uppers else fst t.uppers
  let current_upper t = if t.flip then fst t.uppers else snd t.uppers
  let lower t = Option.get t.lower
  let pp_current_upper ppf t = pp_current_upper ppf t.flip
  let pp_next_upper ppf t = pp_next_upper ppf t.flip

  let mem_lower t k =
    match t.lower with None -> Lwt.return false | Some lower -> L.mem lower k

  let mem_next t k = U.mem (next_upper t) k

  let consume_newies t =
    let newies = t.newies in
    t.newies <- [];
    newies

  let add t v =
    let freeze = t.freeze_in_progress () in
    [%log.debug "add in %a%a" pp_current_upper t pp_during_freeze freeze];
    Irmin_layers.Stats.add ();
    let upper = current_upper t in
    U.add upper v >|= fun k ->
    if freeze then t.newies <- k :: t.newies;
    k

  let unsafe_add t hash v =
    let freeze = t.freeze_in_progress () in
    [%log.debug "unsafe_add in %a%a" pp_current_upper t pp_during_freeze freeze];
    Irmin_layers.Stats.add ();
    let upper = current_upper t in
    let+ k = U.unsafe_add upper hash v in
    if freeze then t.newies <- k :: t.newies;
    k

  let unsafe_append ~ensure_unique ~overcommit t hash v =
    let freeze = t.freeze_in_progress () in
    [%log.debug
      "unsafe_append in %a%a" pp_current_upper t pp_during_freeze freeze];
    Irmin_layers.Stats.add ();
    let upper = current_upper t in
    let k = U.unsafe_append ~ensure_unique ~overcommit upper hash v in
    if freeze then t.newies <- k :: t.newies;
    k

  (** Everything is in current upper, no need to look in next upper. *)
  let find t k =
    let current = current_upper t in
    [%log.debug "find in %a" pp_current_upper t];
    U.find current k >>= function
    | Some v -> Lwt.return_some v
    | None -> (
        match t.lower with
        | None -> Lwt.return_none
        | Some lower ->
            [%log.debug "find in lower"];
            L.find lower k)

  let unsafe_find ~check_integrity t k =
    let current = current_upper t in
    [%log.debug "unsafe_find in %a" pp_current_upper t];
    match U.unsafe_find ~check_integrity current k with
    | Some v -> Some v
    | None -> (
        match t.lower with
        | None -> None
        | Some lower ->
            [%log.debug "unsafe_find in lower"];
            L.unsafe_find ~check_integrity lower k)

  let mem t k =
    let current = current_upper t in
    U.mem current k >>= function
    | true -> Lwt.return_true
    | false -> (
        match t.lower with
        | None -> Lwt.return_false
        | Some lower -> L.mem lower k)

  let index t hash =
    let current = current_upper t in
    U.index current hash >>= function
    | Some _ as r -> Lwt.return r
    | None -> (
        match t.lower with
        | None -> Lwt.return_none
        | Some lower -> L.index lower hash)

  let index_direct t hash =
    let current = current_upper t in
    U.index_direct current hash |> function
    | Some _ as r -> r
    | None -> (
        match t.lower with
        | None -> None
        | Some lower -> L.index_direct lower hash)

  let unsafe_mem t k =
    let current = current_upper t in
    U.unsafe_mem current k
    || match t.lower with None -> false | Some lower -> L.unsafe_mem lower k

  (** Only flush current upper, to prevent concurrent flushing and appends
      during copy. Next upper and lower are flushed at the end of a freeze. *)
  let flush ?index ?index_merge t =
    let current = current_upper t in
    U.flush ?index ?index_merge current

  let flush_next_lower t =
    let next = next_upper t in
    U.flush ~index_merge:true next;
    match t.lower with None -> () | Some x -> L.flush ~index_merge:true x

  let cast t = (t :> read_write t)

  let batch t f =
    f (cast t) >|= fun r ->
    flush ~index:true t;
    r

  (** If the generation changed, then the upper changed too. TODO: This
      assumption is ok for now, but does not hold if:

      - the RW store is opened after the RO,
      - if RW is closed in the meantime,
      - if the RW freezes an even number of times before an RO sync.

      See https://github.com/mirage/irmin/issues/1225 *)
  let sync ?on_generation_change ?on_generation_change_next_upper t =
    [%log.debug "sync %a" pp_current_upper t];
    (* a first implementation where only the current upper is synced *)
    let current = current_upper t in
    let former_generation = U.generation current in
    U.sync ?on_generation_change current;
    let generation = U.generation current in
    if former_generation <> generation then (
      [%log.debug "generation change, RO updates upper"];
      t.flip <- not t.flip;
      let current = current_upper t in
      U.sync ?on_generation_change:on_generation_change_next_upper current;
      match t.lower with None -> () | Some x -> L.sync ?on_generation_change x);
    t.flip

  let update_flip ~flip t = t.flip <- flip

  let close t =
    U.close (fst t.uppers) >>= fun () ->
    U.close (snd t.uppers) >>= fun () ->
    match t.lower with None -> Lwt.return_unit | Some x -> L.close x

  let integrity_check ~offset ~length ~layer k t =
    match layer with
    | `Upper1 -> U.integrity_check ~offset ~length k (fst t.uppers)
    | `Upper0 -> U.integrity_check ~offset ~length k (snd t.uppers)
    | `Lower -> L.integrity_check ~offset ~length k (lower t)

  let layer_id t k =
    let current, upper =
      if t.flip then (fst t.uppers, `Upper1) else (snd t.uppers, `Upper0)
    in
    U.mem current k >>= function
    | true -> Lwt.return upper
    | false -> (
        match t.lower with
        | None -> raise Not_found
        | Some lower -> (
            L.mem lower k >|= function
            | true -> `Lower
            | false -> raise Not_found))

  let clear t =
    U.clear (fst t.uppers) >>= fun () ->
    U.clear (snd t.uppers) >>= fun () ->
    match t.lower with None -> Lwt.return_unit | Some x -> L.clear x

  let clear_keep_generation t =
    U.clear_keep_generation (fst t.uppers) >>= fun () ->
    U.clear_keep_generation (snd t.uppers) >>= fun () ->
    match t.lower with
    | None -> Lwt.return_unit
    | Some x -> L.clear_keep_generation x

  let clear_caches t =
    let current = current_upper t in
    U.clear_caches current

  let clear_caches_next_upper t =
    let next = next_upper t in
    U.clear_caches next

  (** After clearing the previous upper, we also needs to flush current upper to
      disk, otherwise values are not found by the RO. *)
  let clear_previous_upper ?keep_generation t =
    let previous = next_upper t in
    let current = current_upper t in
    U.flush current;
    match keep_generation with
    | Some () -> U.clear_keep_generation previous
    | None -> U.clear previous

  let version t = U.version (fst t.uppers)

  let generation t =
    let current = current_upper t in
    U.generation current

  let offset t =
    let current = current_upper t in
    U.offset current

  let flip_upper t =
    [%log.debug "flip_upper to %a" pp_next_upper t];
    t.flip <- not t.flip

  module CopyUpper = Copy (Key) (U) (U)
  module CopyLower = Copy (Key) (U) (L)

  type 'a layer_type =
    | Upper : read U.t layer_type
    | Lower : read L.t layer_type

  let copy_to_lower t ~dst str k =
    CopyLower.copy ~src:(current_upper t) ~dst str k

  let copy_to_next t ~dst str k =
    CopyUpper.copy ~src:(current_upper t) ~dst str k

  let check t ?none ?some k =
    CopyUpper.check ~src:(current_upper t) ?none ?some k

  let copy : type l. l layer_type * l -> read t -> string -> L.key -> unit =
   fun (ltype, dst) ->
    match ltype with Lower -> copy_to_lower ~dst | Upper -> copy_to_next ~dst

  (** The object [k] can be in either lower or upper. If already in upper then
      do not copy it. *)
  let copy_from_lower t ~dst ?(aux = fun _ -> Lwt.return_unit) str k =
    (* FIXME(samoht): why does this function need to be different from the previous one? *)
    let lower = lower t in
    let current = current_upper t in
    U.find current k >>= function
    | Some v -> aux v
    | None -> (
        L.find lower k >>= function
        | Some v ->
            aux v >>= fun () ->
            stats str;
            U.unsafe_add dst (Key.to_hash k) v >|= ignore
        | None -> Fmt.failwith "%s %a not found" str (Irmin.Type.pp Key.t) k)
end

module Pack_maker
    (H : Irmin.Hash.S)
    (Index : Irmin_pack.Index.S)
    (P : Irmin_pack.Pack_store.Maker
           with type hash = H.t
            and type index := Index.t) =
struct
  type index = Index.t
  type hash = H.t
  type key = H.t Irmin_pack.Pack_key.t

  module Make
      (V : Irmin_pack.Pack_value.S
             with type hash := hash
              and type key := hash Irmin_pack.Pack_key.t) =
  struct
    module Upper = P.Make (V)
    include Indexable (H) (Index) (Upper) (Upper)
  end
end

module Atomic_write
    (K : Irmin.Branch.S)
    (U : Irmin_pack.Atomic_write.Persistent with type key = K.t)
    (L : Irmin_pack.Atomic_write.Persistent
           with type key = U.key
            and type value = U.value) =
struct
  type key = K.t [@@deriving irmin ~equal]
  type value = U.value

  module U = U
  module L = L

  type t = {
    lower : L.t option;
    mutable flip : bool;
    uppers : U.t * U.t;
    freeze_in_progress : unit -> bool;
    mutable newies : (key * value option) list;
  }

  let current_upper t = if t.flip then fst t.uppers else snd t.uppers
  let next_upper t = if t.flip then snd t.uppers else fst t.uppers
  let pp_current_upper ppf t = pp_current_upper ppf t.flip
  let pp_next_upper ppf t = pp_next_upper ppf t.flip
  let pp_branch = Irmin.Type.pp K.t

  let mem t k =
    let current = current_upper t in
    [%log.debug "[branches] mem %a in %a" pp_branch k pp_current_upper t];
    U.mem current k >>= function
    | true -> Lwt.return_true
    | false -> (
        match t.lower with
        | None -> Lwt.return_false
        | Some lower ->
            [%log.debug "[branches] mem in lower"];
            L.mem lower k)

  let find t k =
    let current = current_upper t in
    [%log.debug "[branches] find in %a" pp_current_upper t];
    U.find current k >>= function
    | Some v -> Lwt.return_some v
    | None -> (
        match t.lower with
        | None -> Lwt.return_none
        | Some lower ->
            [%log.debug "[branches] find in lower"];
            L.find lower k)

  let set t k v =
    let freeze = t.freeze_in_progress () in
    [%log.debug
      "[branches] set %a in %a%a" pp_branch k pp_current_upper t
        pp_during_freeze freeze];
    let upper = current_upper t in
    U.set upper k v >|= fun () ->
    if freeze then t.newies <- (k, Some v) :: t.newies

  (** Copy back into upper the branch against we want to do test and set. *)
  let test_and_set t k ~test ~set =
    let freeze = t.freeze_in_progress () in
    [%log.debug
      "[branches] test_and_set %a in %a%a" pp_branch k pp_current_upper t
        pp_during_freeze freeze];
    let current = current_upper t in
    let find_in_lower () =
      (match t.lower with
      | None -> Lwt.return_none
      | Some lower -> L.find lower k)
      >>= function
      | None -> U.test_and_set current k ~test:None ~set
      | Some v ->
          U.set current k v >>= fun () -> U.test_and_set current k ~test ~set
    in
    (U.mem current k >>= function
     | true -> U.test_and_set current k ~test ~set
     | false -> find_in_lower ())
    >|= fun update ->
    if update && freeze then t.newies <- (k, set) :: t.newies;
    update

  let remove t k =
    let freeze = t.freeze_in_progress () in
    [%log.debug
      "[branches] remove %a in %a%a" pp_branch k pp_current_upper t
        pp_during_freeze freeze];
    U.remove (fst t.uppers) k >>= fun () ->
    U.remove (snd t.uppers) k >>= fun () ->
    if freeze then t.newies <- (k, None) :: t.newies;
    match t.lower with
    | None -> Lwt.return_unit
    | Some lower -> L.remove lower k

  let list t =
    let current = current_upper t in
    U.list current >>= fun upper ->
    (match t.lower with None -> Lwt.return_nil | Some lower -> L.list lower)
    >|= fun lower ->
    List.fold_left
      (fun acc b -> if List.mem ~equal:equal_key b acc then acc else b :: acc)
      lower upper

  type watch = U.watch

  let watch t = U.watch (current_upper t)
  let watch_key t = U.watch_key (current_upper t)
  let unwatch t = U.unwatch (current_upper t)

  let close t =
    U.close (fst t.uppers) >>= fun () ->
    U.close (snd t.uppers) >>= fun () ->
    match t.lower with None -> Lwt.return_unit | Some x -> L.close x

  let v upper1 upper0 lower ~flip ~freeze_in_progress =
    { lower; flip; uppers = (upper1, upper0); freeze_in_progress; newies = [] }

  let clear t =
    U.clear (fst t.uppers) >>= fun () ->
    U.clear (snd t.uppers) >>= fun () ->
    match t.lower with None -> Lwt.return_unit | Some x -> L.clear x

  let flush t =
    let current = current_upper t in
    U.flush current

  (** Do not copy branches that point to commits not copied. *)
  let copy ~mem_commit_lower ~mem_commit_upper t =
    let next = next_upper t in
    let current = current_upper t in
    U.list current >>= fun branches ->
    Lwt_list.iter_p
      (fun branch ->
        U.find current branch >>= function
        | None -> Lwt.fail_with "branch not found in current upper"
        | Some hash -> (
            (match t.lower with
            | None -> Lwt.return_unit
            | Some lower -> (
                mem_commit_lower hash >>= function
                | true ->
                    [%log.debug
                      "[branches] copy to lower %a" (Irmin.Type.pp K.t) branch];
                    Irmin_layers.Stats.copy_branches ();
                    L.set lower branch hash
                | false -> Lwt.return_unit))
            >>= fun () ->
            mem_commit_upper hash >>= function
            | true ->
                [%log.debug
                  "[branches] copy to next %a" (Irmin.Type.pp K.t) branch];
                Irmin_layers.Stats.copy_branches ();
                U.set next branch hash
            | false ->
                [%log.debug "branch %a not copied" (Irmin.Type.pp K.t) branch];
                Lwt.return_unit))
      branches

  let flip_upper t =
    [%log.debug "[branches] flip to %a" pp_next_upper t];
    t.flip <- not t.flip

  (** After clearing the previous upper, we also needs to flush current upper to
      disk, otherwise values are not found by the RO. *)
  let clear_previous_upper ?keep_generation t =
    let current = current_upper t in
    let previous = next_upper t in
    U.flush current;
    match keep_generation with
    | Some () -> U.clear_keep_generation previous
    | None -> U.clear previous

  let flush_next_lower t =
    let next = next_upper t in
    U.flush next;
    match t.lower with None -> () | Some x -> L.flush x

  let copy_newies_to_next_upper t =
    [%log.debug
      "[branches] copy %d newies to %a" (List.length t.newies) pp_next_upper t];
    let next = next_upper t in
    let newies = t.newies in
    t.newies <- [];
    Lwt_list.iter_s
      (fun (k, v) ->
        match v with None -> U.remove next k | Some v -> U.set next k v)
      (List.rev newies)

  (** RO syncs the branch store at every find call, but it still needs to update
      the upper in use.*)
  let update_flip ~flip t = t.flip <- flip

  let clear_keep_generation t =
    U.clear_keep_generation (fst t.uppers) >>= fun () ->
    U.clear_keep_generation (snd t.uppers) >>= fun () ->
    match t.lower with
    | None -> Lwt.return_unit
    | Some x -> L.clear_keep_generation x
end
