defmodule Explorer.Chain.RokoEvent do
  @moduledoc """
  Read-only mirror of `roko.events` written by the roko-indexer-sidecar
  (Sprint 5 / S5-T2). Generic event log — captures every event in every
  finalized block, regardless of pallet. Powers the explorer's block
  Events tab and the extrinsic-detail "events emitted" panel.
  """

  use Explorer.Schema

  import Ecto.Query

  @primary_key {:id, :id, autogenerate: true}
  @schema_prefix "roko"
  schema "events" do
    field(:block_number, :integer)
    field(:block_hash, :binary)
    field(:extrinsic_index, :integer)
    field(:phase, :string)
    field(:index_in_block, :integer)
    field(:pallet, :string)
    field(:method, :string)
    field(:data, :map)
    field(:recorded_at, :utc_datetime_usec)
  end

  @doc "All events in a given block, ordered by their in-block index."
  def by_block_query(block_number) when is_integer(block_number) do
    from(e in __MODULE__,
      where: e.block_number == ^block_number,
      order_by: [asc: e.index_in_block]
    )
  end

  @doc "All events emitted by a specific extrinsic within a block."
  def by_extrinsic_query(block_number, extrinsic_index)
      when is_integer(block_number) and is_integer(extrinsic_index) do
    from(e in __MODULE__,
      where: e.block_number == ^block_number and e.extrinsic_index == ^extrinsic_index,
      order_by: [asc: e.index_in_block]
    )
  end
end
