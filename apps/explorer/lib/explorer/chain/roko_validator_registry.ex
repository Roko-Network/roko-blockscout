defmodule Explorer.Chain.RokoValidatorRegistry do
  @moduledoc """
  Read-only mirror of `roko.validator_registry` written by the
  roko-indexer-sidecar (separate Rust binary). One row per Roko Network
  validator, refreshed on every `pallet_session::NewSession` rotation.

  All Roko-specific tables live under the `roko` Postgres schema
  (see `roko_network/sidecar/migrations/`); this Blockscout deploy
  accesses them via Ecto with explicit schema-qualified table names.
  """

  use Explorer.Schema

  import Ecto.Query

  @primary_key {:stash, :binary, autogenerate: false}
  schema "roko.validator_registry" do
    field(:controller, :binary)
    field(:authority_index, :integer)
    field(:session_keys, :map)
    field(:commission_pct, :decimal)
    field(:bonded_amount, :decimal)
    field(:status, :string)
    field(:first_seen_block, :integer)
    field(:last_updated_block, :integer)
  end

  @doc "All active validators ordered by their current authority_index."
  def active_query do
    from(v in __MODULE__,
      where: v.status == "active",
      order_by: [asc: v.authority_index]
    )
  end

  @doc "Lookup by stash (binary 32-byte AccountId32)."
  def by_stash_query(stash_bytes) do
    from(v in __MODULE__, where: v.stash == ^stash_bytes)
  end
end
