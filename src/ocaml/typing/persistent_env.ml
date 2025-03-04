(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*   Xavier Leroy, projet Gallium, INRIA Rocquencourt                     *)
(*   Gabriel Scherer, projet Parsifal, INRIA Saclay                       *)
(*                                                                        *)
(*   Copyright 2019 Institut National de Recherche en Informatique et     *)
(*     en Automatique.                                                    *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(* Persistent structure descriptions *)

open Misc
open Cmi_format

module CU = Compilation_unit
module Consistbl = Consistbl.Make (CU.Name) (CU)

let add_delayed_check_forward = ref (fun _ -> assert false)

type error =
  | Illegal_renaming of CU.Name.t * CU.Name.t * filepath
  | Inconsistent_import of CU.Name.t * filepath * filepath
  | Need_recursive_types of CU.t
  | Depend_on_unsafe_string_unit of CU.t
  | Inconsistent_package_declaration of CU.t * filepath
  | Inconsistent_package_declaration_between_imports of
      filepath * CU.t * CU.t
  | Direct_reference_from_wrong_package of
      CU.t * filepath * CU.Prefix.t

exception Error of error
let error err = raise (Error err)

module Persistent_signature = struct
  type t =
    { filename : string;
      cmi : Cmi_format.cmi_infos }

  let load = ref (fun ~unit_name ->
      let unit_name = CU.Name.to_string unit_name in
      match Load_path.find_uncap (unit_name ^ ".cmi") with
      | filename ->
        let cmi = Cmi_cache.read filename in
        Some { filename; cmi }
      | exception Not_found -> None)
end

type can_load_cmis =
  | Can_load_cmis
  | Cannot_load_cmis of Lazy_backtrack.log

type pers_struct = {
  ps_name: CU.t;
  ps_crcs: Import_info.t array;
  ps_filename: string;
  ps_flags: pers_flags list;
}

(* If a .cmi file is missing (or invalid), we
   store it as Missing in the cache. *)
type 'a pers_struct_info =
  | Missing
  | Found of pers_struct * 'a

type 'a t = {
  persistent_structures :
    (CU.Name.t, 'a pers_struct_info) Hashtbl.t;
  imported_units: CU.Name.Set.t ref;
  imported_opaque_units: CU.Name.Set.t ref;
  crc_units: Consistbl.t;
  can_load_cmis: can_load_cmis ref;
  short_paths_basis: Short_paths.Basis.t ref;
}

let empty () = {
  persistent_structures = Hashtbl.create 17;
  imported_units = ref CU.Name.Set.empty;
  imported_opaque_units = ref CU.Name.Set.empty;
  crc_units = Consistbl.create ();
  can_load_cmis = ref Can_load_cmis;
  short_paths_basis = ref (Short_paths.Basis.create ());
}

let clear penv =
  let {
    persistent_structures;
    imported_units;
    imported_opaque_units;
    crc_units;
    can_load_cmis;
    short_paths_basis;
  } = penv in
  Hashtbl.clear persistent_structures;
  imported_units := CU.Name.Set.empty;
  imported_opaque_units := CU.Name.Set.empty;
  Consistbl.clear crc_units;
  can_load_cmis := Can_load_cmis;
  short_paths_basis := Short_paths.Basis.create ();
  ()

let clear_missing {persistent_structures; _} =
  let missing_entries =
    Hashtbl.fold
      (fun name r acc -> if r = Missing then name :: acc else acc)
      persistent_structures []
  in
  List.iter (Hashtbl.remove persistent_structures) missing_entries

let add_import {imported_units; _} s =
  imported_units := CU.Name.Set.add s !imported_units

let register_import_as_opaque {imported_opaque_units; _} s =
  imported_opaque_units := CU.Name.Set.add s !imported_opaque_units

let find_in_cache {persistent_structures; _} s =
  match Hashtbl.find persistent_structures s with
  | exception Not_found -> None
  | Missing -> None
  | Found (_ps, pm) -> Some pm

let import_crcs penv ~source crcs =
  let {crc_units; _} = penv in
  let import_crc import_info =
    let name = Import_info.name import_info in
    let crco = Import_info.crc_with_unit import_info in
    match crco with
    | None -> ()
    | Some (unit, crc) ->
        add_import penv name;
        Consistbl.check crc_units name unit crc source
  in Array.iter import_crc crcs

let check_consistency penv ps =
  try import_crcs penv ~source:ps.ps_filename ps.ps_crcs
  with Consistbl.Inconsistency {
      unit_name = name;
      inconsistent_source = source;
      original_source = auth;
      inconsistent_data = source_unit;
      original_data = auth_unit;
    } ->
    if CU.equal source_unit auth_unit
    then error (Inconsistent_import(name, auth, source))
    else error (Inconsistent_package_declaration_between_imports(
        ps.ps_filename, auth_unit, source_unit))

let can_load_cmis penv =
  !(penv.can_load_cmis)
let set_can_load_cmis penv setting =
  penv.can_load_cmis := setting
let short_paths_basis penv =
  !(penv.short_paths_basis)

let without_cmis penv f x =
  let log = Lazy_backtrack.log () in
  let res =
    Misc.(protect_refs
            [R (penv.can_load_cmis, Cannot_load_cmis log)]
            (fun () -> f x))
  in
  Lazy_backtrack.backtrack log;
  res

let fold {persistent_structures; _} f x =
  Hashtbl.fold (fun modname pso x -> match pso with
      | Missing -> x
      | Found (_, pm) -> f modname pm x)
    persistent_structures x

let register_pers_for_short_paths penv ps components =
  let old_style_crcs =
    ps.ps_crcs
    |> Array.to_list
    |> List.map
         (fun import ->
            let name = Import_info.name import in
            let crc_with_unit = Import_info.crc_with_unit import in
            name, crc_with_unit)
  in
  let deps, alias_deps =
    List.fold_left
      (fun (deps, alias_deps) (name, digest) ->
         let name_as_string = Compilation_unit.Name.to_string name in
         Short_paths.Basis.add (short_paths_basis penv) name_as_string;
         match digest with
         | None -> deps, name_as_string :: alias_deps
         | Some _ -> name_as_string :: deps, alias_deps)
      ([], []) old_style_crcs
  in
  let desc =
    Short_paths.Desc.Module.(Fresh (Signature components))
  in
  let is_deprecated =
    List.exists
      (function
        | Alerts alerts ->
          String.Map.mem "deprecated" alerts ||
          String.Map.mem "ocaml.deprecated" alerts
        | _ -> false)
      ps.ps_flags
  in
  let deprecated =
    if is_deprecated then Short_paths.Desc.Deprecated
    else Short_paths.Desc.Not_deprecated
  in
  let ps_name_as_string = Compilation_unit.name_as_string ps.ps_name in
  Short_paths.Basis.load (short_paths_basis penv) ps_name_as_string
    deps alias_deps desc deprecated
(* Reading persistent structures from .cmi files *)

let save_pers_struct penv crc ps pm =
  let {persistent_structures; crc_units; _} = penv in
  let modname = CU.name ps.ps_name in
  Hashtbl.add persistent_structures modname (Found (ps, pm));
  List.iter
    (function
        | Rectypes -> ()
        | Alerts _ -> ()
        | Unsafe_string -> ()
        | Opaque -> register_import_as_opaque penv modname)
    ps.ps_flags;
  Consistbl.set crc_units modname ps.ps_name crc ps.ps_filename;
  add_import penv modname

let acknowledge_pers_struct penv short_path_comps check modname pers_sig pm =
  let { Persistent_signature.filename; cmi } = pers_sig in
  let name = cmi.cmi_name in
  let crcs = cmi.cmi_crcs in
  let flags = cmi.cmi_flags in
  let ps = { ps_name = name;
             ps_crcs = crcs;
             ps_filename = filename;
             ps_flags = flags;
           } in
  let found_name = CU.name name in
  if not (CU.Name.equal modname found_name) then
    error (Illegal_renaming(modname, found_name, filename));
  List.iter
    (function
        | Rectypes ->
            if not !Clflags.recursive_types then
              error (Need_recursive_types(ps.ps_name))
        | Unsafe_string ->
            if Config.safe_string then
              error (Depend_on_unsafe_string_unit(ps.ps_name));
        | Alerts _ -> ()
        | Opaque -> register_import_as_opaque penv modname)
    ps.ps_flags;
  if check then check_consistency penv ps;
  begin match CU.get_current () with
  | Some current_unit ->
      let access_allowed =
        CU.can_access_by_name name ~accessed_by:current_unit
      in
      if not access_allowed then
        let prefix = CU.for_pack_prefix current_unit in
        error (Direct_reference_from_wrong_package (name, filename, prefix));
  | None -> ()
  end;
  let {persistent_structures; _} = penv in
  Hashtbl.add persistent_structures modname (Found (ps, pm));
  register_pers_for_short_paths penv ps (short_path_comps ps.ps_name pm);
  ps

let read_pers_struct penv val_of_pers_sig short_path_comps check modname filename =
  add_import penv modname;
  let cmi = Cmi_cache.read filename in
  let pers_sig = { Persistent_signature.filename; cmi } in
  let pm = val_of_pers_sig pers_sig in
  let ps = acknowledge_pers_struct penv short_path_comps check modname pers_sig pm in
  (ps, pm)

let find_pers_struct penv val_of_pers_sig short_path_comps check name =
  let {persistent_structures; _} = penv in
  if CU.Name.equal name CU.Name.predef_exn then raise Not_found;
  match Hashtbl.find persistent_structures name with
  | Found (ps, pm) -> (ps, pm)
  | Missing -> raise Not_found
  | exception Not_found ->
    match can_load_cmis penv with
    | Cannot_load_cmis _ -> raise Not_found
    | Can_load_cmis ->
        let psig =
          match !Persistent_signature.load ~unit_name:name with
          | Some psig -> psig
          | None ->
            Hashtbl.add persistent_structures name Missing;
            raise Not_found
        in
        add_import penv name;
        let pm = val_of_pers_sig psig in
        let ps = acknowledge_pers_struct penv short_path_comps check name psig pm in
        (ps, pm)

let describe_prefix ppf prefix =
  if CU.Prefix.is_empty prefix then
    Format.fprintf ppf "outside of any package"
  else
    Format.fprintf ppf "package %a" CU.Prefix.print prefix

(* Emits a warning if there is no valid cmi for name *)
let check_pers_struct penv f1 f2 ~loc name =
  let name_as_string = CU.Name.to_string name in
  try
    ignore (find_pers_struct penv f1 f2 false name)
  with
  | Not_found ->
      let warn = Warnings.No_cmi_file(name_as_string, None) in
        Location.prerr_warning loc warn
  | Magic_numbers.Cmi.Error err ->
      let msg = Format.asprintf "%a" Magic_numbers.Cmi.report_error err in
      let warn = Warnings.No_cmi_file(name_as_string, Some msg) in
        Location.prerr_warning loc warn
  | Error err ->
      let msg =
        match err with
        | Illegal_renaming(name, ps_name, filename) ->
            Format.asprintf
              " %a@ contains the compiled interface for @ \
               %a when %a was expected"
              Location.print_filename filename
              CU.Name.print ps_name
              CU.Name.print name
        | Inconsistent_import _ -> assert false
        | Need_recursive_types name ->
            Format.asprintf
              "%a uses recursive types"
              CU.print name
        | Depend_on_unsafe_string_unit name ->
            Format.asprintf "%a uses -unsafe-string"
              CU.print name
        | Inconsistent_package_declaration _ -> assert false
        | Inconsistent_package_declaration_between_imports _ -> assert false
        | Direct_reference_from_wrong_package (unit, _filename, prefix) ->
            Format.asprintf "%a is inaccessible from %a"
              CU.print unit
              describe_prefix prefix
      in
      let warn = Warnings.No_cmi_file(name_as_string, Some msg) in
        Location.prerr_warning loc warn

let read penv f1 f2 modname filename =
  snd (read_pers_struct penv f1 f2 true modname filename)

let find penv f1 f2 name =
  snd (find_pers_struct penv f1 f2 true name)

let check penv f1 f2 ~loc name =
  let {persistent_structures; _} = penv in
  if not (Hashtbl.mem persistent_structures name) then begin
    (* PR#6843: record the weak dependency ([add_import]) regardless of
       whether the check succeeds, to help make builds more
       deterministic. *)
    add_import penv name;
    if (Warnings.is_active (Warnings.No_cmi_file("", None))) then
      !add_delayed_check_forward
        (fun () -> check_pers_struct penv f1 f2 ~loc name)
  end

(* CR mshinwell: delete this having moved to 4.14 build compilers *)
module Array = struct
  include Array

  (* From stdlib/array.ml *)
  let find_opt p a =
    let n = Array.length a in
    let rec loop i =
      if i = n then None
      else
        let x = Array.unsafe_get a i in
        if p x then Some x
        else loop (succ i)
    in
    loop 0
end

let crc_of_unit penv f1 f2 name =
  let (ps, _pm) = find_pers_struct penv f1 f2 true name in
  match Array.find_opt (Import_info.has_name ~name) ps.ps_crcs with
  | None -> assert false
  | Some import_info ->
    match Import_info.crc import_info with
    | None -> assert false
    | Some crc -> crc

let imports {imported_units; crc_units; _} =
  let imports =
    Consistbl.extract (CU.Name.Set.elements !imported_units)
      crc_units
  in
  List.map (fun (cu_name, crc_with_unit) ->
      Import_info.create cu_name ~crc_with_unit)
    imports

let looked_up {persistent_structures; _} modname =
  Hashtbl.mem persistent_structures modname

let is_imported {imported_units; _} s =
  CU.Name.Set.mem s !imported_units

let is_imported_opaque {imported_opaque_units; _} s =
  CU.Name.Set.mem s !imported_opaque_units

let make_cmi penv modname sign alerts =
  let flags =
    List.concat [
      if !Clflags.recursive_types then [Cmi_format.Rectypes] else [];
      if !Clflags.opaque then [Cmi_format.Opaque] else [];
      (if !Clflags.unsafe_string then [Cmi_format.Unsafe_string] else []);
      [Alerts alerts];
    ]
  in
  let crcs = imports penv in
  {
    cmi_name = modname;
    cmi_sign = sign;
    cmi_crcs = Array.of_list crcs;
    cmi_flags = flags
  }

let save_cmi penv psig pm =
  let { Persistent_signature.filename; cmi } = psig in
  Misc.try_finally (fun () ->
      let {
        cmi_name = modname;
        cmi_sign = _;
        cmi_crcs = imports;
        cmi_flags = flags;
      } = cmi in
      let crc =
        output_to_file_via_temporary (* see MPR#7472, MPR#4991 *)
          ~mode: [Open_binary] filename
          (fun temp_filename oc -> output_cmi temp_filename oc cmi) in
      (* Enter signature in persistent table so that imports()
         will also return its crc *)
      let ps =
        { ps_name = modname;
          ps_crcs =
            Array.append
              [| Import_info.create_normal cmi.cmi_name ~crc:(Some crc) |]
              imports;
          ps_filename = filename;
          ps_flags = flags;
        } in
      save_pers_struct penv crc ps pm
    )
    ~exceptionally:(fun () -> remove_file filename)

let report_error ppf =
  let open Format in
  function
  | Illegal_renaming(modname, ps_name, filename) -> fprintf ppf
      "Wrong file naming: %a@ contains the compiled interface for@ \
       %a when %a was expected"
      Location.print_filename filename
      CU.Name.print ps_name
      CU.Name.print modname
  | Inconsistent_import(name, source1, source2) -> fprintf ppf
      "@[<hov>The files %a@ and %a@ \
              make inconsistent assumptions@ over interface %a@]"
      Location.print_filename source1 Location.print_filename source2
      CU.Name.print name
  | Need_recursive_types(import) ->
      fprintf ppf
        "@[<hov>Invalid import of %a, which uses recursive types.@ %s@]"
        CU.print import
        "The compilation flag -rectypes is required"
  | Depend_on_unsafe_string_unit(import) ->
      fprintf ppf
        "@[<hov>Invalid import of %a, compiled with -unsafe-string.@ %s@]"
        CU.print import
        "This compiler has been configured in strict \
                           safe-string mode (-force-safe-string)"
  | Inconsistent_package_declaration(intf_package, intf_filename) ->
      fprintf ppf
        "@[<hov>The interface %a@ is compiled for package %s.@ %s@]"
        CU.print intf_package intf_filename
        "The compilation flag -for-pack with the same package is required"
  | Inconsistent_package_declaration_between_imports (filename, unit1, unit2) ->
      fprintf ppf
        "@[<hov>The file %s@ is imported both as %a@ and as %a.@]"
        filename
        CU.print unit1
        CU.print unit2
  | Direct_reference_from_wrong_package(unit, filename, prefix) ->
      fprintf ppf
        "@[<hov>Invalid reference to %a (in file %s) from %a.@ %s]"
        CU.print unit
        filename
        describe_prefix prefix
        "Can only access members of this library's package or a containing package"

let () =
  Location.register_error_of_exn
    (function
      | Error err ->
          Some (Location.error_of_printer_file report_error err)
      | _ -> None
    )

(* helper for merlin *)

let with_cmis penv f x =
  Misc.(protect_refs
          [R (penv.can_load_cmis, Can_load_cmis)]
          (fun () -> f x))

let forall ~found ~missing t =
  Std.Hashtbl.forall t.persistent_structures (fun name -> function
      | Missing -> missing name
      | Found (pers_struct, a) ->
        found name pers_struct.ps_filename pers_struct.ps_name a
    )
