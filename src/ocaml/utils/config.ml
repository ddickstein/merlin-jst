(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*             Xavier Leroy, projet Cristal, INRIA Rocquencourt           *)
(*                                                                        *)
(*   Copyright 1996 Institut National de Recherche en Informatique et     *)
(*     en Automatique.                                                    *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(***********************************************************************)
(**                                                                   **)
(**               WARNING WARNING WARNING                             **)
(**                                                                   **)
(** When you change this file, you must make the parallel change      **)
(** in config.mlbuild                                                 **)
(**                                                                   **)
(***********************************************************************)

(* merlin-jst: All magic numbers ending in "500" should not change when we
   upgrade the upstream Merlin version.  Otherwise, this should track
   "utils/config.mlp" from the compiler.  Also, the above warning comment about
   "config.mlbuild" is outdated and can be ignored. *)

(* The main OCaml version string has moved to ../VERSION *)
let version = Sys.ocaml_version

let flambda = false

let exec_magic_number = "Caml1999X500"
    (* exec_magic_number is duplicated in runtime/caml/exec.h *)
and cmi_magic_number = "Caml1999I501"
and cmo_magic_number = "Caml1999O501"
and cma_magic_number = "Caml1999A501"
and cmx_magic_number =
  if flambda then
    "Caml2021y503"
  else
    "Caml2021Y503"
and cmxa_magic_number =
  if flambda then
    "Caml2021z503"
  else
    "Caml2021Z503"
and ast_impl_magic_number = "Caml1999M031"
and ast_intf_magic_number = "Caml1999N031"
and cmxs_magic_number = "Caml1999D502"
and cmt_magic_number = "Caml1999T501"

let interface_suffix = ref ".mli"

let max_tag = 245

let safe_string = true
let flat_float_array = false

let merlin = true
