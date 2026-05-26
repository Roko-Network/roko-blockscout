defmodule Explorer.Chain.RokoExtrinsic do
  @moduledoc """
  Read-only mirror of `roko.extrinsics` written by the roko-indexer-sidecar
  (Sprint 5 / S5-T1). One row per substrate extrinsic in every finalized
  block — the foundation of the explorer's "Substrate Extrinsics" block-tab,
  address tab, and extrinsic-detail page.
  """

  use Explorer.Schema

  import Ecto.Query

  @primary_key {:id, :id, autogenerate: true}
  @schema_prefix "roko"
  schema "extrinsics" do
    field(:block_number, :integer)
    field(:block_hash, :binary)
    field(:index_in_block, :integer)
    field(:pallet, :string)
    field(:method, :string)
    field(:args, :map)
    field(:args_truncated, :boolean)
    field(:signer, :binary)
    field(:signature, :binary)
    field(:tip, :decimal)
    field(:era, :map)
    field(:nonce, :integer)
    field(:fee_paid, :decimal)
    field(:success, :boolean)
    field(:error, :map)
    field(:hash, :binary)
    field(:call_hash, :binary)
    field(:extrinsic_class, :string)
    field(:recorded_at, :utc_datetime_usec)
  end

  @doc "All extrinsics in a given block, ordered by their in-block index."
  def by_block_query(block_number) when is_integer(block_number) do
    from(e in __MODULE__,
      where: e.block_number == ^block_number,
      order_by: [asc: e.index_in_block]
    )
  end

  @doc "Extrinsics signed by an account, newest first."
  def by_signer_query(signer_bytes, limit \\ 100) when is_binary(signer_bytes) do
    from(e in __MODULE__,
      where: e.signer == ^signer_bytes,
      order_by: [desc: e.block_number, desc: e.index_in_block],
      limit: ^limit
    )
  end

  @doc """
  Lookup by either the encoded-extrinsic hash or the call hash. Both are
  32 bytes; polkadot.js identifies unsigned/inherent extrinsics by call_hash
  and signed by hash, so callers don't know which one a user pasted — try
  both.
  """
  def by_hash_query(hash_bytes) when is_binary(hash_bytes) do
    from(e in __MODULE__,
      where: e.hash == ^hash_bytes or e.call_hash == ^hash_bytes,
      limit: 1
    )
  end

  @doc """
  Per-block extrinsic counts for a batch of block numbers. Used by the
  EVM-side blocks list to enrich each row with a substrate count column.
  """
  def counts_by_blocks_query(block_numbers) when is_list(block_numbers) do
    from(e in __MODULE__,
      where: e.block_number in ^block_numbers,
      group_by: e.block_number,
      select: {e.block_number, count(e.id)}
    )
  end

  @doc """
  Recent feed, optionally filtered by (pallet, method) and paginated via a
  `(block_number, index_in_block)` cursor. Pass the `next_page_params` from
  the previous response back as `:before_block` + `:before_index` to scroll
  backwards through the feed.
  """
  def recent_query(opts \\ []) do
    pallet = Keyword.get(opts, :pallet)
    method = Keyword.get(opts, :method)
    limit = Keyword.get(opts, :limit, 50)
    before_block = Keyword.get(opts, :before_block)
    before_index = Keyword.get(opts, :before_index)

    base =
      from(e in __MODULE__,
        order_by: [desc: e.block_number, desc: e.index_in_block],
        limit: ^limit
      )

    base = if pallet, do: from(e in base, where: e.pallet == ^pallet), else: base
    base = if method, do: from(e in base, where: e.method == ^method), else: base

    if is_integer(before_block) and is_integer(before_index) do
      from(e in base,
        where:
          e.block_number < ^before_block or
            (e.block_number == ^before_block and e.index_in_block < ^before_index)
      )
    else
      base
    end
  end
end
