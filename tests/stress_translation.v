Require Import Weakly.Effects.

Inductive empty: Type := . Print sigT.

Inductive vec (A: Type): nat -> Type :=
| vnil: vec A 0
| vconst: forall n, A -> vec A n -> vec A (S n).

Effect List Translate empty unit bool nat list vec sum sig sigT.
Effect List Translate False True and or ex eq.

Definition match_type_to_type (A: Type) (l: list A) := 
  match l with
  | nil => true
  | cons _ _ => false
  end.

Effect Translate match_type_to_type.

Definition match_type_to_True (b: bool): True :=
  match b with true => I | false => I end.
Fail Effect Translate match_type_to_True.

Definition match_type_to_prop (b: bool): Prop :=
  match b with true => True | false => False end.
Fail Effect Translate match_type_to_prop.

Definition match_prop_to_prop (A B: Prop) (s: A /\ B): A :=
  match s with conj a _ => a end.
Effect Translate match_prop_to_prop.

Fail Definition match_prop_to_type (A B: Prop) (s: A \/ B): bool :=
  if s then true else false.

(** This is allowed, but it is never generated by the translation *)
Definition keep_an_eye (E: Type) (e: E) := Err (Propᵉ E) e.