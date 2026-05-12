defmodule Explorer.Chain.RokoEraSummary do
  @moduledoc """
  Read-only mirror of `roko.era_summaries` written by the roko-indexer-sidecar.
  One row per era; finalized=true once `pallet_staking::EraPaid` lands.
  """

  use Explorer.Schema

  import Ecto.Query

  @primary_key {:era_index, :integer, autogenerate: false}
  schema "roko.era_summaries" do
    field(:start_block, :integer)
    field(:end_block, :integer)
    field(:start_session, :integer)
    field(:end_session, :integer)
    field(:validator_count, :integer)
    field(:total_stake, :decimal)
    field(:validator_payout, :decimal)
    field(:remainder_payout, :decimal)
    field(:slashed_count, :integer)
    field(:slashed_total, :decimal)
    field(:finalized, :boolean)
    field(:finalized_at_block, :integer)
    field(:updated_at, :utc_datetime_usec)
  end

  def recent_query(limit \\ 20) do
    from(e in __MODULE__,
      order_by: [desc: e.era_index],
      limit: ^limit
    )
  end
end

defmodule Explorer.Chain.RokoSlashingEvent do
  @moduledoc """
  Read-only mirror of `roko.slashing_events`. One row per
  pallet_staking::Slashed or pallet_offences::Offence event.
  """

  use Explorer.Schema

  import Ecto.Query

  @primary_key {:id, :id, autogenerate: true}
  schema "roko.slashing_events" do
    field(:era_index, :integer)
    field(:block_number, :integer)
    field(:block_hash, :binary)
    field(:extrinsic_index, :integer)
    field(:stash, :binary)
    field(:offence_kind, :string)
    field(:slash_amount, :decimal)
    field(:reporters, {:array, :binary})
    field(:detail, :map)
    field(:recorded_at, :utc_datetime_usec)
  end

  def recent_query(limit \\ 50) do
    from(s in __MODULE__,
      order_by: [desc: s.block_number, desc: s.id],
      limit: ^limit
    )
  end

  def for_stash_query(stash_bytes, limit \\ 100) do
    from(s in __MODULE__,
      where: s.stash == ^stash_bytes,
      order_by: [desc: s.block_number, desc: s.id],
      limit: ^limit
    )
  end
end
