defmodule Explorer.Chain.RokoTimesyncViolation do
  @moduledoc """
  Read-only mirror of `roko.timesync_violations` written by the
  roko-indexer-sidecar. One row per `pallet_timesync::TemporalViolation`
  or `TemporalOffenceReported` event.
  """

  use Explorer.Schema

  import Ecto.Query

  @primary_key {:id, :id, autogenerate: true}
  schema "roko.timesync_violations" do
    field(:block_number, :integer)
    field(:block_hash, :binary)
    field(:extrinsic_index, :integer)
    field(:stash, :binary)
    field(:authority_index, :integer)
    field(:kind, :string)
    field(:severity, :string)
    field(:detail, :map)
    field(:escalated, :boolean)
    field(:recorded_at, :utc_datetime_usec)
  end

  def by_authority_query(authority_index, limit \\ 100) do
    from(v in __MODULE__,
      where: v.authority_index == ^authority_index,
      order_by: [desc: v.block_number, desc: v.id],
      limit: ^limit
    )
  end

  def by_stash_query(stash_bytes, limit \\ 100) do
    from(v in __MODULE__,
      where: v.stash == ^stash_bytes,
      order_by: [desc: v.block_number, desc: v.id],
      limit: ^limit
    )
  end

  def recent_query(limit \\ 50) do
    from(v in __MODULE__,
      order_by: [desc: v.block_number, desc: v.id],
      limit: ^limit
    )
  end
end
