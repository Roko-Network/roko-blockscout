defmodule Explorer.Chain.RokoPwrokoTransfer do
  @moduledoc """
  Read-only mirror of `roko.pwroko_transfers` written by the
  roko-indexer-sidecar. One row per pallet_pwroko event (12 variants).
  """

  use Explorer.Schema

  import Ecto.Query

  @primary_key {:id, :id, autogenerate: true}
  schema "roko.pwroko_transfers" do
    field(:block_number, :integer)
    field(:block_hash, :binary)
    field(:extrinsic_index, :integer)
    field(:event_kind, :string)
    field(:from_account, :binary)
    field(:to_account, :binary)
    field(:amount, :decimal)
    field(:backing_amount, :decimal)
    field(:extra, :map)
  end

  def for_account_query(account_bytes, limit \\ 100) do
    from(t in __MODULE__,
      where: t.from_account == ^account_bytes or t.to_account == ^account_bytes,
      order_by: [desc: t.block_number, desc: t.id],
      limit: ^limit
    )
  end

  def by_event_kind_query(kind, limit \\ 100) do
    from(t in __MODULE__,
      where: t.event_kind == ^kind,
      order_by: [desc: t.block_number, desc: t.id],
      limit: ^limit
    )
  end
end
