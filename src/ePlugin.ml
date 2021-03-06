open CErrors
open Pp
open Util
open Names
open Term
open Decl_kinds
open Libobject
open Mod_subst
open Globnames

(** Utilities *)

let translate_name id =
  let id = Id.to_string id in
  Id.of_string (id ^ "ᵉ")

(** Record of translation between globals *)

type translator = ETranslate.translator

let empty_translator = 
  let open ETranslate in 
  let refss = [
      (param_cst, param_cst_e);
      (tm_exception, tm_exception_e);
      (tm_raise, tm_raise_e)
    ]
  in
  let map acc (s,t) = 
    Cmap.add s (GlobGen (ConstRef t)) acc
  in
  let refss = List.fold_left map Cmap.empty refss in 
  let inds = Mindmap.add param_mod (GlobGen param_mod_e) Mindmap.empty in
  let prefs = Cmap.empty in
  let pinds = Mindmap.empty in
  {
    ETranslate.refs = refss;
    inds = inds;
    prefs = prefs;
    pinds = pinds;
    wrefs = Cmap.empty;
    winds = Mindmap.empty;
    paramrefs = Mindmap.empty;
    paraminds = Mindmap.empty;
  }

let translator : translator ref =
  Summary.ref ~name:"Effect Global Table" empty_translator

type extension_type =
| ExtEffect
| ExtParam

type extension =
| ExtConstant of Constant.t * global_reference
| ExtInductive of MutInd.t * MutInd.t
| ExtParamInductive of MutInd.t * MutInd.t
| ExtParamConstant of MutInd.t * global_reference

type translator_obj =
| ExtendEffect of extension_type * global_reference option * extension list

let extend_constant exn cst gr map = match exn with
| None -> Cmap.add cst (ETranslate.GlobGen gr) map
| Some exn ->
  let old =
    try Cmap.find cst map
    with Not_found -> ETranslate.GlobImp Refmap.empty
  in
  match old with
  | ETranslate.GlobImp imp ->
    let imp = Refmap.add exn gr imp in
    Cmap.add cst (ETranslate.GlobImp imp) map
  | ETranslate.GlobGen _ -> assert false

let extend_inductive exn ind nind map = match exn with
| None -> Mindmap.add ind (ETranslate.GlobGen nind) map
| Some exn ->
  let old =
    try Mindmap.find ind map
    with Not_found -> ETranslate.GlobImp Refmap.empty
  in
  match old with
  | ETranslate.GlobImp imp ->
    let imp = Refmap.add exn nind imp in
    Mindmap.add ind (ETranslate.GlobImp imp) map
  | ETranslate.GlobGen _ -> assert false

let extend_translator tr knd exn l =
  let open ETranslate in
  let fold accu ext = match knd, ext with
  | ExtEffect, ExtConstant (cst, gr) ->
    { accu with refs = extend_constant exn cst gr accu.refs }
  | ExtEffect, ExtInductive (mind, mind') ->
    { accu with inds = extend_inductive exn mind mind' accu.inds }
  | ExtParam, ExtConstant (cst, gr) ->
    { accu with prefs = extend_constant exn cst gr accu.prefs }
  | ExtParam, ExtInductive (mind, mind') ->
    { accu with pinds = extend_inductive exn mind mind' accu.pinds }
  | _ -> accu
  in
  List.fold_left fold tr l

let cache_translator (_, l) = match l with
| ExtendEffect (knd, exn, l) ->
  translator := extend_translator !translator knd exn l

let load_translator _ obj = cache_translator obj
let open_translator _ obj = cache_translator obj

let subst_extension subst ext = match ext with
| ExtConstant (cst, gr) ->
  let cst' = subst_constant subst cst in
  let gr' = subst_global_reference subst gr in
  if cst' == cst && gr' == gr then ext
  else ExtConstant (cst', gr')
| ExtInductive (smind, tmind) ->
  let smind' = subst_mind subst smind in
  let tmind' = subst_mind subst tmind in
  if smind' == smind && tmind' == tmind then ext
  else ExtInductive (smind', tmind')
(** what !!! *)
| ExtParamConstant (smind, gr) ->
  let smind' = subst_mind subst smind in
  let gr' = subst_global_reference subst gr in
  if smind' == smind && gr' == gr then ext
  else ExtParamConstant (smind', gr')
| ExtParamInductive (smind, tmind) ->
  let smind' = subst_mind subst smind in
  let tmind' = subst_mind subst tmind in
  if smind' == smind && tmind' == tmind then ext
  else ExtParamInductive (smind', tmind')

let subst_translator (subst, obj) = match obj with
| ExtendEffect (knd, exn, l) ->
  let exn' = Option.smartmap (fun gr -> subst_global_reference subst gr) exn in
  let l' = List.smartmap (fun e -> subst_extension subst e) l in
  if exn' == exn && l' == l then obj else ExtendEffect (knd, exn', l')

let in_translator : translator_obj -> obj =
  declare_object { (default_object "FORCING TRANSLATOR") with
    cache_function = cache_translator;
    load_function = load_translator;
    open_function = open_translator;
    discharge_function = (fun (_, o) -> Some o);
    classify_function = (fun o -> Substitute o);
    subst_function = subst_translator;
  }

(** Tactic *)

let solve_evars env sigma c =
  let evdref = ref sigma in
  let c = Typing.e_solve_evars env evdref c in
  (!evdref, c)

let declare_axiom id uctx ty =
  let uctx = Entries.Monomorphic_const_entry uctx in
  let pe = (None, (ty, uctx), None) in
  let pd = Entries.ParameterEntry pe in  
  let decl = (pd, IsAssumption Definitional) in
  let cst_ = Declare.declare_constant id decl in
  cst_

let declare_constant id uctx c t =
  let uctx = Entries.Monomorphic_const_entry uctx in
  let ce = Declare.definition_entry ~types:t ~univs:uctx c in
  let cd = Entries.DefinitionEntry ce in
  let decl = (cd, IsProof Lemma) in
  let cst_ = Declare.declare_constant id decl in
  cst_

let declare_constant_wo_ty id uctx c = 
  let uctx = Entries.Monomorphic_const_entry uctx in
  let ce = Declare.definition_entry ~univs:uctx c in
  let cd = Entries.DefinitionEntry ce in
  let decl = (cd, IsProof Lemma) in
  let cst_ = Declare.declare_constant id decl in
  cst_

let on_one_id f ids cst = match ids with
| None -> f (Nametab.basename_of_global (ConstRef cst))
| Some [id] -> id
| Some _ -> user_err (str "Not the right number of provided names")

let translate_constant err translator cst ids =
  let id = on_one_id translate_name ids cst in
  (** Translate the type *)
  let env = Global.env () in
  let (typ, uctx) = Global.type_of_global_in_context env (ConstRef cst) in
  let typ = EConstr.of_constr typ in
  let sigma = Evd.from_env env in
  let (sigma, typ) = ETranslate.translate_type err translator env sigma typ in
  let sigma, _ = Typing.type_of env sigma typ in
  let body, _ = Option.get (Global.body_of_constant cst) in
  let body = EConstr.of_constr body in
  let (sigma, body) = ETranslate.translate err translator env sigma body in
  let evdref = ref sigma in
  let () = Typing.e_check env evdref body typ in
  let sigma = !evdref in
  let body = EConstr.to_constr sigma body in
  let typ = EConstr.to_constr sigma typ in
  let uctx = UState.context_set (Evd.evar_universe_context sigma) in
  let cst_ = declare_constant id uctx body typ in
  [ExtConstant (cst, ConstRef cst_)]

(** Fix potential mismatch between the generality of parametricity and effect
    translations *)
let instantiate_error env sigma err gen c_ = match err with
| None -> (sigma, c_)
| Some err ->
  if gen then
    let (sigma, err) = Evd.fresh_global env sigma err in
    (sigma, mkApp (c_, [| err |]))
  else (sigma, c_)

let primitives_from_declaration env (ind: Names.mutual_inductive) =
  let open Declarations in 
  let (mind, _) = Inductive.lookup_mind_specif env (ind, 0) in  
  let (_, projs, _) = Option.get (Option.get mind.mind_record) in
  Array.to_list projs

let translate_inductive_gen f err translator (ind, _) =
  let env = Global.env () in
  let (mind, _ as specif) = Inductive.lookup_mind_specif env (ind, 0) in

  let primitive_records = Inductive.is_primitive_record specif in 

  let mind' = EUtil.process_inductive mind in
  let mind_ = f err translator env ind mind mind' in
  let ((_, kn), _) = Declare.declare_mind mind_ in
  let ind_ = Global.mind_of_delta_kn kn in
  let extensions = 
    if primitive_records then 
      let env = Global.env () in
      let proj  = primitives_from_declaration env ind in 
      let proj_ = primitives_from_declaration env ind_ in 
      let pair = List.combine proj proj_ in
      List.map (fun (p, pe) -> ExtConstant (p, ConstRef pe)) pair
    else
      []
  in
  (ExtInductive (ind, ind_)) :: extensions

let one_ind_in_prop ind_arity =
  let open Declarations in
  match ind_arity with
  | RegularArity ar -> is_prop_sort ar.mind_sort
  | TemplateArity _ -> false

let typeclass_declaration err translator ind_names_decl ind_name param_ind =
  let env = Global.env () in
  let func = ETranslate.param_instance_inductive in
  
  let (sigma, base_instance_ty, pinstance) = func err translator env ind_names_decl param_ind in
  
  (* Polymorphic Axiom declaration *)
  let id = Nameops.add_suffix ind_name  "_instance" in
  let uctx = UState.context_set (Evd.evar_universe_context sigma) in
  let instance_name = declare_axiom id uctx (EConstr.to_constr sigma base_instance_ty) in
  let _,dirPath,label = Constant.repr3 instance_name in
  let qualid = Libnames.make_qualid dirPath (Label.to_id label) in
  let () = Classes.existing_instance true (CAst.make (Libnames.Qualid qualid)) None in
  (* -- *)
  
  let pid = translate_name id in
  let tp = EConstr.to_constr sigma pinstance in
  let pinstance_name = declare_constant_wo_ty pid uctx tp in
  ExtConstant (instance_name, ConstRef pinstance_name)

let instantiate_parametric_modality err translator (name, n) ext = 
  let module D = Declarations in 
  let env = Global.env () in
  let (mind, _ as specif) = Inductive.lookup_mind_specif env (name, 0) in
  let find_map = function
    | ExtInductive (n,m) when MutInd.equal name n -> Some m
    | _ -> None
  in
  let name_e = List.find_map find_map ext in 
  let global_app name = match err with
    | None -> ETranslate.GlobGen name
    | Some exn -> ETranslate.GlobImp (Refmap.singleton exn name)
  in
  let translator = 
    ETranslate.({ translator with inds = Mindmap.add name (global_app name_e) translator.inds }) 
  in
  let mind' = EUtil.process_inductive mind in
  let mind_ = ETranslate.param_mutual_inductive err translator env (name, name_e) mind mind' in

  let ((_, kn), _) = Declare.declare_mind mind_ in
  let name_param = Global.mind_of_delta_kn kn in 
  let iter id = 
    let id_ind = Nameops.add_suffix id "_ind" in
    let reference = CAst.make @@ Misctypes.AN (CAst.make (Libnames.Ident id)) in
    let scheme = Vernacexpr.InductionScheme (true, reference, InProp) in
    Indschemes.do_scheme [Some (CAst.make id_ind), scheme]
  in
  let mind_names = Entries.(List.map (fun i -> i.mind_entry_typename) mind_.mind_entry_inds) in
  let () = List.iter iter mind_names in

  let ind_name_decl = (name, name_e, name_param) in
  let ty_decl = typeclass_declaration in 
  let fold_map (i, translator) one_d =
    let open ETranslate in 
    let ext = ty_decl err translator ind_name_decl D.(one_d.mind_typename) (one_d, i) in
    let refs = match ext with
      | ExtConstant (cst, glob_ref) -> Cmap.add cst (global_app glob_ref) translator.refs
      | _ -> translator.refs
    in
    let translator = { translator with refs } in
    ((succ i, translator), ext)
  in
  let ((_, translator), instances) = 
    List.fold_map fold_map (0, translator) (Array.to_list D.(mind.mind_packets)) 
  in
  let env = Global.env () in
  let (sigma, ind, ind_e, ind_e_ty) = ETranslate.parametric_induction err translator env name mind in

  
  (* Parametrict induction *)
  let name = Declarations.(mind.mind_packets.(0).mind_typename) in
  let induction_name = Nameops.add_suffix name "_ind_param" in
  let uctx = UState.context_set (Evd.evar_universe_context sigma) in
  let cst_ind = declare_axiom induction_name uctx (EConstr.to_constr sigma ind) in

  let induction_name_e = Nameops.add_suffix induction_name "ᵉ" in
  let uctx = UState.context_set (Evd.evar_universe_context sigma) in
  let ind_e = EConstr.to_constr sigma ind_e in
  let ind_e_ty = EConstr.to_constr sigma ind_e_ty in
  let cst_ind_e = declare_constant induction_name_e uctx ind_e ind_e_ty in
  (* ********************* *)

  ExtConstant (cst_ind, ConstRef cst_ind_e) :: instances  

let try_instantiate_parametric_modality err translator (name, n) ext  =
  let module D = Declarations in 
  let env = Global.env () in
  let (mind, _ as specif) = Inductive.lookup_mind_specif env (name, 0) in
  let arity_mind = Array.map (fun ind -> D.(ind.mind_arity) ) D.(mind.mind_packets) in

  if Array.exists (fun i -> one_ind_in_prop i) arity_mind then []
  else instantiate_parametric_modality err translator (name, n) ext

let translate_inductive err translator ind =
  let base_ext = translate_inductive_gen ETranslate.translate_inductive err translator ind in
  let inst = try_instantiate_parametric_modality err translator ind base_ext in
  base_ext @ inst

let msg_translate = function
| ExtConstant (cst, gr) ->
  (str "Global " ++ Printer.pr_global (ConstRef cst) ++
  str " has been translated as " ++ Printer.pr_global gr ++ str ".")
| ExtInductive (smind, tmind) ->
  let mib = Global.lookup_mind smind in
  let len = Array.length mib.Declarations.mind_packets in
  let l = List.init len (fun n -> (IndRef (smind, n), IndRef (tmind, n))) in
  let pr (src, dst) =
    (str "Global " ++ Printer.pr_global src ++
    str " has been translated as " ++ Printer.pr_global dst ++ str ".")
  in
  prlist_with_sep fnl pr l
| ExtParamInductive _ -> 
   str "Parametric inducitve extension"
| ExtParamConstant _ ->
   str "Parametric constant extension"

let translate ?exn ?names gr =
  let ids = names in
  let err = Option.map Nametab.global exn in
  let gr = Nametab.global gr in
  let translator = !translator in
  let ans = match gr with
  | ConstRef cst -> translate_constant err translator cst ids
  | IndRef ind -> translate_inductive err translator ind
  | ConstructRef _ -> user_err (str "Use the translation over the corresponding inductive type instead.")
  | VarRef _ -> user_err (str "Variable translation not handled.")
  in
  let ext = ExtendEffect (ExtEffect, err, ans) in
  let () = Lib.add_anonymous_leaf (in_translator ext) in
  let msg = prlist_with_sep fnl msg_translate ans in
  Feedback.msg_info msg

(** Implementation in the forcing layer *)

let implement ?exn id typ =
  let env = Global.env () in
  let translator = !translator in
  let err = Option.map Nametab.global exn in
  let id_ = translate_name id in
  let sigma = Evd.from_env env in
  let (typ, uctx) = Constrintern.interp_type env sigma typ in
  let sigma = Evd.from_ctx uctx in
  let (sigma, typ) = solve_evars env sigma typ in
  let (sigma, typ_) = ETranslate.translate_type err translator env sigma typ in
  let typ = EConstr.to_constr sigma typ in
  let (sigma, _) = Typing.type_of env sigma typ_ in
  let hook _ dst =
    (** Declare the original term as an axiom *)
    let param = (None, (typ, Entries.Monomorphic_const_entry (Evd.evar_universe_context_set uctx)), None) in
    let cb = Entries.ParameterEntry param in
    let cst = Declare.declare_constant id (cb, IsDefinition Definition) in
    (** Attach the axiom to the forcing implementation *)
    let ext = ExtendEffect (ExtEffect, err, [ExtConstant (cst, dst)]) in
    Lib.add_anonymous_leaf (in_translator ext)
  in
  let hook ctx = Lemmas.mk_hook hook in
  let sigma, _ = Typing.type_of env sigma typ_ in
  let kind = Global, false, DefinitionBody Definition in
  let () = Lemmas.start_proof_univs id_ kind sigma typ_ hook in
  ()

(** Error handling *)

let pr_global = function
| VarRef id -> str "Variable " ++ Nameops.pr_id id
| ConstRef cst -> str "Constant " ++ Constant.print cst
| IndRef (ind, _) -> str "Inductive " ++ MutInd.print ind
| ConstructRef ((ind, _), _) -> str "Inductive " ++ MutInd.print ind

let _ = register_handler begin function
| ETranslate.MissingGlobal (eff, gr) ->
  let eff = match eff with
  | None -> str "for generic exceptions"
  | Some gr -> str "for instance" ++ spc () ++ Printer.pr_global gr
  in
  str "No translation for global " ++ Printer.pr_global gr ++ spc () ++ eff ++ str "."
| ETranslate.MissingPrimitive gr ->
  let ref = pr_global gr in
  str "Missing primitive: " ++ ref ++ str "."
| ETranslate.MatchEliminationNotSupportedOnTranslation ->
   str "Elimination error: this match is not allowed under the translation"
| _ -> raise Unhandled
end

(** List translate *)

module Generic = struct
  open Libnames
  open Names
         
  let generic_translate ?exn
        (gr_list:reference list) 
        (generic: ?exn:reference -> ?names:Id.t list-> reference -> unit) =
    let fold () gr = generic ?exn gr in
    List.fold_left fold () gr_list
end
open Generic
                      
let list_translate ?exn gr_list =
  generic_translate ?exn gr_list translate
