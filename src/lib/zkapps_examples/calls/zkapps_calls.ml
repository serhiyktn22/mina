open Core_kernel
open Snark_params.Tick.Run
open Signature_lib
open Mina_base

(** The type underlying the opaque call data digest field used by the call
    rules.
*)
module Call_data = struct
  (** The type of inputs that the zkApp rules receive when called by another
      zkApp.
  *)
  module Input = struct
    module Constant = struct
      type t = { old_state : Field.Constant.t } [@@deriving hlist]

      let to_random_oracle_input { old_state } =
        Random_oracle_input.Chunked.field_elements [| old_state |]
    end

    module Circuit = struct
      type t = { old_state : Field.t } [@@deriving hlist]

      let to_random_oracle_input { old_state } =
        Random_oracle_input.Chunked.field_elements [| old_state |]
    end

    let typ =
      Typ.of_hlistable ~value_to_hlist:Constant.to_hlist
        ~value_of_hlist:Constant.of_hlist ~var_to_hlist:Circuit.to_hlist
        ~var_of_hlist:Circuit.of_hlist [ Field.typ ]
  end

  (** The type of outputs that the zkApp rules receive when called by another
      zkApp.
  *)
  module Output = struct
    module Constant = struct
      type t =
        { blinding_value : Field.Constant.t
              (** A random value, mixed into the hash with the returned value.

                  This is used to hide the contents of the inter-app call's
                  arguments and return values from the protocol, so that one
                  zkApp can make assertions about private data on behalf on
                  another zkApp, or otherwise keep data secret.
                  When chosen at random, the probability of an adversary
                  finding the correct value is negligible (1 in ~2^254).
              *)
        ; new_state : Field.Constant.t
        }
      [@@deriving hlist]

      let to_random_oracle_input { blinding_value; new_state } =
        Random_oracle_input.Chunked.field_elements
          [| blinding_value; new_state |]
    end

    module Circuit = struct
      type t = { blinding_value : Field.t; new_state : Field.t }
      [@@deriving hlist]

      let to_random_oracle_input { blinding_value; new_state } =
        Random_oracle_input.Chunked.field_elements
          [| blinding_value; new_state |]
    end

    let typ =
      Typ.of_hlistable ~value_to_hlist:Constant.to_hlist
        ~value_of_hlist:Constant.of_hlist ~var_to_hlist:Circuit.to_hlist
        ~var_of_hlist:Circuit.of_hlist [ Field.typ; Field.typ ]
  end

  module Constant = struct
    type t = { input : Input.Constant.t; output : Output.Constant.t }
    [@@deriving hlist]

    let to_random_oracle_input { input; output } =
      Random_oracle_input.Chunked.append
        (Input.Constant.to_random_oracle_input input)
        (Output.Constant.to_random_oracle_input output)

    let digest (t : t) =
      let open Random_oracle in
      to_random_oracle_input t |> pack_input
      |> update ~state:initial_state
      |> digest
  end

  module Circuit = struct
    type t = { input : Input.Circuit.t; output : Output.Circuit.t }
    [@@deriving hlist]

    let to_random_oracle_input { input; output } =
      Random_oracle_input.Chunked.append
        (Input.Circuit.to_random_oracle_input input)
        (Output.Circuit.to_random_oracle_input output)

    let digest (t : t) =
      let open Random_oracle.Checked in
      to_random_oracle_input t |> pack_input
      |> update ~state:initial_state
      |> digest
  end

  let typ =
    Typ.of_hlistable ~value_to_hlist:Constant.to_hlist
      ~value_of_hlist:Constant.of_hlist ~var_to_hlist:Circuit.to_hlist
      ~var_of_hlist:Circuit.of_hlist [ Input.typ; Output.typ ]
end

(** Circuit requests, to get values and run code outside of the snark. *)
type _ Snarky_backendless.Request.t +=
  | Public_key : Public_key.Compressed.t Snarky_backendless.Request.t
  | Caller : Token_id.t Snarky_backendless.Request.t
  | Old_state : Field.Constant.t Snarky_backendless.Request.t
  | (* TODO: Tweak pickles so this can be an explicit input. *)
      Get_call_input :
      Call_data.Input.Constant.t Snarky_backendless.Request.t
  | Increase_amount : Field.Constant.t Snarky_backendless.Request.t
  | Delegate_call : bool Snarky_backendless.Request.t
  | Execute_call :
      (Token_id.t * Call_data.Input.Constant.t)
      -> ( Call_data.Output.Constant.t
         * Zkapp_call_forest.account_update
         * Zkapp_call_forest.t )
         Snarky_backendless.Request.t

(** Helper function for executing zkApp calls.

    The particular details of the called account update are determined by the handler
    for the [Execute_call] request.
*)
let execute_call ~caller account_update old_state =
  let call_inputs = { Call_data.Input.Circuit.old_state } in
  let call_outputs, called_account_update, sub_calls =
    exists
      (Typ.tuple3 Call_data.Output.typ
         (Zkapp_call_forest.Checked.account_update_typ ())
         Zkapp_call_forest.typ )
      ~request:(fun () ->
        let caller = As_prover.read Token_id.typ caller in
        let input = As_prover.read Call_data.Input.typ call_inputs in
        Execute_call (caller, input) )
  in
  let () =
    (* Check that previous account update's call data is consistent. *)
    let call_data_digest =
      Call_data.Circuit.digest { input = call_inputs; output = call_outputs }
    in
    Field.Assert.equal call_data_digest
      called_account_update.account_update.data.call_data
  in
  let () =
    (* Check that the caller is the one that we specified *)
    Token_id.Checked.Assert.equal caller
      called_account_update.account_update.data.caller
  in
  account_update#register_call called_account_update sub_calls ;
  call_outputs.new_state

module Rules = struct
  (** Rule to initialize the zkApp.

      Asserts that the state was not last updated by a proof (ie. the zkApp is
      freshly deployed, or that the state was modified -- tampered with --
      without using a proof).
      The app state is set to the initial state.
  *)
  module Initialize_state = struct
    (** State to initialize the zkApp to after deployment. *)
    let initial_state = lazy (List.init 8 ~f:(fun _ -> Field.Constant.zero))

    (** The request handler for the rule. *)
    let handler (public_key : Public_key.Compressed.t)
        (Snarky_backendless.Request.With { request; respond }) =
      match request with
      | Public_key ->
          respond (Provide public_key)
      | _ ->
          respond Unhandled

    let main input =
      let public_key =
        exists Public_key.Compressed.typ ~request:(fun () -> Public_key)
      in
      Zkapps_examples.wrap_main ~public_key
        (fun account_update ->
          let initial_state =
            List.map ~f:Field.constant (Lazy.force initial_state)
          in
          account_update#assert_state_unproved ;
          account_update#set_full_state initial_state ;
          None )
        input

    let rule : _ Pickles.Inductive_rule.t =
      { identifier = "Initialize snapp"; prevs = []; main; uses_lookup = false }
  end

  (** Rule to update the zkApp state.

      Asserts that the state was last updated by a proof (ie. that the zkApp
      has been correctly initialized, and all subsequent updates have been via
      proof executions).

      This calls into another zkApp method whose shape matches [Call_data], and
      uses the output value as the new state.
  *)
  module Update_state = struct
    (** The request handler for the rule. *)
    let handler (public_key : Public_key.Compressed.t)
        (old_state : Field.Constant.t) (call_kind : Account_update.Call_type.t)
        (execute_call :
             Token_id.t
          -> Call_data.Input.Constant.t
          -> Call_data.Output.Constant.t
             * Zkapp_call_forest.account_update
             * Zkapp_call_forest.t )
        (Snarky_backendless.Request.With { request; respond }) =
      match request with
      | Public_key ->
          respond (Provide public_key)
      | Old_state ->
          respond (Provide old_state)
      | Delegate_call ->
          let delegate_call =
            match call_kind with Call -> false | Delegate_call -> true
          in
          respond (Provide delegate_call)
      | Execute_call (caller, input) ->
          respond (Provide (execute_call caller input))
      | _ ->
          respond Unhandled

    let main input =
      let public_key =
        exists Public_key.Compressed.typ ~request:(fun () -> Public_key)
      in
      Zkapps_examples.wrap_main ~public_key
        (fun account_update ->
          let caller =
            let self_caller =
              Account_id.Checked.derive_token_id
                ~owner:
                  (Account_id.Checked.create public_key
                     Token_id.(Checked.constant default) )
            in
            let delegate_call =
              exists Boolean.typ ~request:(fun () -> Delegate_call)
            in
            Token_id.Checked.if_ delegate_call
              ~then_:Token_id.(Checked.constant default)
              ~else_:self_caller
          in
          let old_state = exists Field.typ ~request:(fun () -> Old_state) in
          let new_state = execute_call ~caller account_update old_state in
          account_update#assert_state_proved ;
          account_update#set_state 0 new_state ;
          None )
        input

    let rule : _ Pickles.Inductive_rule.t =
      { identifier = "Update state"; prevs = []; main; uses_lookup = false }
  end

  (** Callable zkApp addition rule.

      Takes the input from the call data, increases it by a number determined
      by the prover (via the [Increase_amount] request), and constructs the
      call data
{[
  { input = { old_state }
  ; output =
    { blinding_value = random () ; new_state = old_state + increase_amount } }
]}

      This also returns the [output] part of the call data to the prover, so
      that it can be passed to the calling zkApp execution.
  *)
  module Add = struct
    (** The request handler for the rule. *)
    let handler (public_key : Public_key.Compressed.t)
        (call_input : Call_data.Input.Constant.t) (caller : Token_id.t)
        (increase_amount : Field.Constant.t)
        (Snarky_backendless.Request.With { request; respond }) =
      match request with
      | Public_key ->
          respond (Provide public_key)
      | Get_call_input ->
          respond (Provide call_input)
      | Increase_amount ->
          respond (Provide increase_amount)
      | Caller ->
          respond (Provide caller)
      | _ ->
          respond Unhandled

    let main input =
      let caller = exists Token_id.typ ~request:(fun () -> Caller) in
      let public_key =
        exists Public_key.Compressed.typ ~request:(fun () -> Public_key)
      in
      Zkapps_examples.wrap_main ~public_key ~caller
        (fun account_update ->
          let input =
            exists Call_data.Input.typ ~request:(fun () -> Get_call_input)
          in
          let blinding_value =
            exists Field.typ ~compute:Field.Constant.random
          in
          let increase_amount =
            exists Field.typ ~request:(fun () -> Increase_amount)
          in
          let new_state = Field.add input.old_state increase_amount in
          let output = { Call_data.Output.Circuit.blinding_value; new_state } in
          let call_data_digest = Call_data.Circuit.digest { input; output } in
          account_update#set_call_data call_data_digest ;
          Some output )
        input

    let rule : _ Pickles.Inductive_rule.t =
      { identifier = "Add method"; prevs = []; main; uses_lookup = false }
  end

  (** Callable zkApp addition-and-call rule.

      Takes the input from the call data, increases it by a number determined
      by the prover (via the [Increase_amount] request), and passes the result
      as the input to another zkApp call method whose shape matches
      [Call_data].
      The return value is exposed to the caller by constructing the call data
{[
  { input = { old_state }
  ; output =
    { blinding_value = random ()
    ; new_state = call_other_zkapp(old_state + increase_amount) } }
]}

      This also returns the [output] part of the call data to the prover, so
      that it can be passed to the calling zkApp execution.
  *)
  module Add_and_call = struct
    (** The request handler for the rule. *)
    let handler (public_key : Public_key.Compressed.t)
        (add_and_call_input : Call_data.Input.Constant.t)
        (increase_amount : Field.Constant.t) (caller : Token_id.t)
        (call_kind : Account_update.Call_type.t)
        (execute_call :
             Token_id.t
          -> Call_data.Input.Constant.t
          -> Call_data.Output.Constant.t
             * Zkapp_call_forest.account_update
             * Zkapp_call_forest.t )
        (Snarky_backendless.Request.With { request; respond }) =
      match request with
      | Public_key ->
          respond (Provide public_key)
      | Get_call_input ->
          respond (Provide add_and_call_input)
      | Increase_amount ->
          respond (Provide increase_amount)
      | Execute_call (caller, input) ->
          respond (Provide (execute_call caller input))
      | Caller ->
          respond (Provide caller)
      | Delegate_call ->
          let delegate_call =
            match call_kind with Call -> false | Delegate_call -> true
          in
          respond (Provide delegate_call)
      | _ ->
          respond Unhandled

    let main input =
      let caller = exists Token_id.typ ~request:(fun () -> Caller) in
      let public_key =
        exists Public_key.Compressed.typ ~request:(fun () -> Public_key)
      in
      Zkapps_examples.wrap_main ~public_key ~caller
        (fun account_update ->
          let ({ Call_data.Input.Circuit.old_state } as call_inputs) =
            exists Call_data.Input.typ ~request:(fun () -> Get_call_input)
          in
          let blinding_value =
            exists Field.typ ~compute:Field.Constant.random
          in
          let increase_amount =
            exists Field.typ ~request:(fun () -> Increase_amount)
          in
          let intermediate_state = Field.add old_state increase_amount in
          let caller =
            let self_caller =
              Account_id.Checked.derive_token_id
                ~owner:
                  (Account_id.Checked.create public_key
                     Token_id.(Checked.constant default) )
            in
            let delegate_call =
              exists Boolean.typ ~request:(fun () -> Delegate_call)
            in
            Token_id.Checked.if_ delegate_call ~then_:caller ~else_:self_caller
          in
          let new_state =
            execute_call ~caller account_update intermediate_state
          in
          let call_outputs =
            { Call_data.Output.Circuit.blinding_value; new_state }
          in
          let call_data_hash =
            Call_data.Circuit.digest
              { input = call_inputs; output = call_outputs }
          in
          account_update#set_call_data call_data_hash ;
          Some call_outputs )
        input

    let rule : _ Pickles.Inductive_rule.t =
      { identifier = "Add-and-call method"
      ; prevs = []
      ; main
      ; uses_lookup = false
      }
  end
end