(*
 * Copyright (c) 2013 Thomas Gazagnaire <thomas@gazagnaire.org>
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

open Lwt

let debug fmt =
  IrminLog.debug "RPC" fmt

exception Error of string

let uri t path =
  Uri.with_path t (String.concat "/" path)

let response fn = function
  | None       -> fail (Error "response")
  | Some (_,b) ->
    Cohttp_lwt_body.string_of_body b >>= function b ->
      let j = IrminJSON.input b in
      let j = IrminJSON.to_dict j in
      let error =
        try Some (List.assoc "error" j)
        with Not_found -> None in
      let result =
        try Some (List.assoc "result" j)
        with Not_found -> None in
      match error, result with
      | None  , None   -> fail (Error "response")
      | Some e, None   -> fail (Error (IrminJSON.output e))
      | None  , Some r -> return (fn r)
      | Some _, Some _ -> fail (Error "response")


let get t path fn =
  Cohttp_lwt_unix.Client.get (uri t path) >>= response fn

let post t path body fn =
  Cohttp_lwt_unix.Client.post ~body (uri t path) >>= response fn

module type S = sig
  val uri: Uri.t
end

module X (S: S) (K: IrminKey.BINARY) (V: IrminBase.S) = struct

  type t = Uri.t

  type key = K.t

  type value = V.t

  let some fn x =
    Some (fn x)

  let unknown k =
    fail (K.Unknown (K.of_string k))

  let create () =
    return S.uri

  let read t key =
    debug "read %s" (K.pretty key);
    catch
      (fun () -> get t ["read"; K.to_hex key] (some V.of_json))
      (fun _  -> return_none)

  let read_exn t key =
    debug "read_exn %s" (K.pretty key);
    get t ["read"; K.to_hex key] V.of_json

  let mem t key =
    debug "mem %s" (K.pretty key);
    get t ["mem"; K.to_hex key] IrminJSON.to_bool

  let list t key =
    debug "list %s" (K.pretty key);
    get t ["list"; K.to_hex key] (IrminJSON.to_list K.of_json)

end

module A (S: S) (K: IrminKey.BINARY) (V: IrminBase.S) = struct

  include X(S)(K)(V)

  let add _ =
    failwith "TODO"

end

module M (S: S) (K: IrminKey.BINARY) (V: IrminBase.S) = struct

  include X(S)(K)(V)

  let update _ =
    failwith "TODO"

  let remove _ =
    failwith "TODO"

end

let simple uri =
  let module SV = struct
    let uri = uri ["value"]
  end in
  let module STr = struct
    let uri = uri ["tree"]
  end in
  let module SR = struct
    let uri = uri ["revision"]
  end in
  let module STa = struct
    let uri = uri ["tag"]
  end in
  let module K = IrminKey.SHA1 in
  let module V = IrminValue.Simple in
  let module Simple = Irmin.Make
      (K)(IrminValue.Simple)(IrminTag.Simple)
      (A(SV))
      (A(STr))
      (A(SR))
      (M(STa)) in
  (module Simple: Irmin.S)