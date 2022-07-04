module Scalar_challenge = Scalar_challenge
module Endo = Endo
open Core_kernel
open Async_kernel
open Pickles_types
open Hlist
module Tick_field_sponge = Tick_field_sponge
module Util = Util
module Step_main_inputs = Step_main_inputs
module Backend = Backend
module Sponge_inputs = Sponge_inputs
module Impls = Impls
module Inductive_rule = Inductive_rule
module Tag = Tag
module Types_map = Types_map
module Step_verifier = Step_verifier
module Common = Common

module type Statement_intf = sig
  type field

  type t

  val to_field_elements : t -> field array
end

module type Statement_var_intf =
  Statement_intf with type field := Impls.Step.Field.t

module type Statement_value_intf =
  Statement_intf with type field := Impls.Step.field

module Verification_key : sig
  [%%versioned:
  module Stable : sig
    module V2 : sig
      type t [@@deriving to_yojson]
    end
  end]

  (* combinator generated by `deriving fields` in implementation *)
  val index : t -> Impls.Wrap.Verification_key.t

  val dummy : t Lazy.t

  module Id : sig
    type t [@@deriving sexp, equal]

    val dummy : unit -> t

    val to_string : t -> string
  end

  val load :
       cache:Key_cache.Spec.t list
    -> Id.t
    -> (t * [ `Cache_hit | `Locally_generated ]) Deferred.Or_error.t
end

module type Proof_intf = sig
  type statement

  type t

  val verification_key : Verification_key.t Lazy.t

  val id : Verification_key.Id.t Lazy.t

  val verify : (statement * t) list -> bool Deferred.t

  val verify_promise : (statement * t) list -> bool Promise.t
end

module Proof : sig
  type ('max_width, 'mlmb) t

  val dummy : 'w Nat.t -> 'm Nat.t -> _ Nat.t -> domain_log2:int -> ('w, 'm) t

  module Make (W : Nat.Intf) (MLMB : Nat.Intf) : sig
    type nonrec t = (W.n, MLMB.n) t [@@deriving sexp, compare, yojson, hash]
  end

  module Proofs_verified_2 : sig
    [%%versioned:
    module Stable : sig
      module V2 : sig
        type t = Make(Nat.N2)(Nat.N2).t
        [@@deriving sexp, compare, equal, yojson, hash]

        val to_yojson_full : t -> Yojson.Safe.t
      end
    end]

    val to_yojson_full : t -> Yojson.Safe.t
  end
end

module Statement_with_proof : sig
  type ('s, 'max_width, _) t = 's * ('max_width, 'max_width) Proof.t
end

val verify_promise :
     (module Nat.Intf with type n = 'n)
  -> (module Statement_value_intf with type t = 'a)
  -> Verification_key.t
  -> ('a * ('n, 'n) Proof.t) list
  -> bool Promise.t

val verify :
     (module Nat.Intf with type n = 'n)
  -> (module Statement_value_intf with type t = 'a)
  -> Verification_key.t
  -> ('a * ('n, 'n) Proof.t) list
  -> bool Deferred.t

module Prover : sig
  type ('prev_values, 'local_widths, 'local_heights, 'a_value, 'proof) t =
       ?handler:
         (   Snarky_backendless.Request.request
          -> Snarky_backendless.Request.response )
    -> ( 'prev_values
       , 'local_widths
       , 'local_heights )
       H3.T(Statement_with_proof).t
    -> 'a_value
    -> 'proof
end

module Provers : module type of H3_2.T (Prover)

module Dirty : sig
  type t = [ `Cache_hit | `Generated_something | `Locally_generated ]

  val ( + ) : t -> t -> t
end

module Cache_handle : sig
  type t

  val generate_or_load : t -> Dirty.t
end

module Side_loaded : sig
  module Verification_key : sig
    [%%versioned:
    module Stable : sig
      module V2 : sig
        type t [@@deriving sexp, equal, compare, hash, yojson]
      end
    end]

    val to_base58_check : t -> string

    val of_base58_check : string -> t Or_error.t

    val of_base58_check_exn : string -> t

    val dummy : t

    open Impls.Step

    val to_input : t -> Field.Constant.t Random_oracle_input.Chunked.t

    module Checked : sig
      type t

      val to_input : t -> Field.t Random_oracle_input.Chunked.t
    end

    val typ : (Checked.t, t) Impls.Step.Typ.t

    val of_compiled : _ Tag.t -> t

    module Max_branches : Nat.Add.Intf

    module Max_width = Nat.N2
  end

  module Proof : sig
    [%%versioned:
    module Stable : sig
      module V2 : sig
        (* TODO: This should really be able to be any width up to the max width... *)
        type t =
          (Verification_key.Max_width.n, Verification_key.Max_width.n) Proof.t
        [@@deriving sexp, equal, yojson, hash, compare]

        val to_base64 : t -> string

        val of_base64 : string -> (t, string) Result.t
      end
    end]

    val of_proof : _ Proof.t -> t

    val to_base64 : t -> string

    val of_base64 : string -> (t, string) Result.t
  end

  val create :
       name:string
    -> max_proofs_verified:(module Nat.Add.Intf with type n = 'n1)
    -> uses_lookup:Plonk_types.Opt.Flag.t
    -> typ:('var, 'value) Impls.Step.Typ.t
    -> ('var, 'value, 'n1, Verification_key.Max_branches.n) Tag.t

  val verify_promise :
       typ:('var, 'value) Impls.Step.Typ.t
    -> (Verification_key.t * 'value * Proof.t) list
    -> bool Promise.t

  val verify :
       typ:('var, 'value) Impls.Step.Typ.t
    -> (Verification_key.t * 'value * Proof.t) list
    -> bool Deferred.t

  (* Must be called in the inductive rule snarky function defining a
     rule for which this tag is used as a predecessor. *)
  val in_circuit :
    ('var, 'value, 'n1, 'n2) Tag.t -> Verification_key.Checked.t -> unit

  (* Must be called immediately before calling the prover for the inductive rule
     for which this tag is used as a predecessor. *)
  val in_prover : ('var, 'value, 'n1, 'n2) Tag.t -> Verification_key.t -> unit

  val srs_precomputation : unit -> unit
end

(** This compiles a series of inductive rules defining a set into a proof
    system for proving membership in that set, with a prover corresponding
    to each inductive rule. *)
val compile_promise :
     ?self:('var, 'value, 'max_proofs_verified, 'branches) Tag.t
  -> ?cache:Key_cache.Spec.t list
  -> ?disk_keys:
       (Cache.Step.Key.Verification.t, 'branches) Vector.t
       * Cache.Wrap.Key.Verification.t
  -> (module Statement_var_intf with type t = 'a_var)
  -> (module Statement_value_intf with type t = 'a_value)
  -> public_input:
       ( 'var
       , 'value
       , 'a_var
       , 'a_value
       , 'ret_var
       , 'ret_value )
       Inductive_rule.public_input
  -> auxiliary_typ:('auxiliary_var, 'auxiliary_value) Impls.Step.Typ.t
  -> branches:(module Nat.Intf with type n = 'branches)
  -> max_proofs_verified:(module Nat.Add.Intf with type n = 'max_proofs_verified)
  -> name:string
  -> constraint_constants:Snark_keys_header.Constraint_constants.t
  -> choices:
       (   self:('var, 'value, 'max_proofs_verified, 'branches) Tag.t
        -> ( 'prev_varss
           , 'prev_valuess
           , 'widthss
           , 'heightss
           , 'a_var
           , 'a_value
           , 'ret_var
           , 'ret_value
           , 'auxiliary_var
           , 'auxiliary_value )
           H4_6.T(Inductive_rule).t )
  -> ('var, 'value, 'max_proofs_verified, 'branches) Tag.t
     * Cache_handle.t
     * (module Proof_intf
          with type t = ('max_proofs_verified, 'max_proofs_verified) Proof.t
           and type statement = 'value )
     * ( 'prev_valuess
       , 'widthss
       , 'heightss
       , 'a_value
       , ( 'ret_value
         * 'auxiliary_value
         * ('max_proofs_verified, 'max_proofs_verified) Proof.t )
         Promise.t )
       H3_2.T(Prover).t

(** This compiles a series of inductive rules defining a set into a proof
    system for proving membership in that set, with a prover corresponding
    to each inductive rule. *)
val compile :
     ?self:('var, 'value, 'max_proofs_verified, 'branches) Tag.t
  -> ?cache:Key_cache.Spec.t list
  -> ?disk_keys:
       (Cache.Step.Key.Verification.t, 'branches) Vector.t
       * Cache.Wrap.Key.Verification.t
  -> (module Statement_var_intf with type t = 'a_var)
  -> (module Statement_value_intf with type t = 'a_value)
  -> public_input:
       ( 'var
       , 'value
       , 'a_var
       , 'a_value
       , 'ret_var
       , 'ret_value )
       Inductive_rule.public_input
  -> auxiliary_typ:('auxiliary_var, 'auxiliary_value) Impls.Step.Typ.t
  -> branches:(module Nat.Intf with type n = 'branches)
  -> max_proofs_verified:(module Nat.Add.Intf with type n = 'max_proofs_verified)
  -> name:string
  -> constraint_constants:Snark_keys_header.Constraint_constants.t
  -> choices:
       (   self:('var, 'value, 'max_proofs_verified, 'branches) Tag.t
        -> ( 'prev_varss
           , 'prev_valuess
           , 'widthss
           , 'heightss
           , 'a_var
           , 'a_value
           , 'ret_var
           , 'ret_value
           , 'auxiliary_var
           , 'auxiliary_value )
           H4_6.T(Inductive_rule).t )
  -> ('var, 'value, 'max_proofs_verified, 'branches) Tag.t
     * Cache_handle.t
     * (module Proof_intf
          with type t = ('max_proofs_verified, 'max_proofs_verified) Proof.t
           and type statement = 'value )
     * ( 'prev_valuess
       , 'widthss
       , 'heightss
       , 'a_value
       , ( 'ret_value
         * 'auxiliary_value
         * ('max_proofs_verified, 'max_proofs_verified) Proof.t )
         Deferred.t )
       H3_2.T(Prover).t
