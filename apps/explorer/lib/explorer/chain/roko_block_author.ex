defmodule Explorer.Chain.RokoBlockAuthor do
  @moduledoc """
  Read-only mirror of `roko.block_authors` written by the roko-indexer-sidecar
  (Sprint 5 / S5-T3). One row per finalized block with the BABE-decoded
  authority_index and the joined author stash from the validator_registry.

  Frontier's `miner` field is null on a non-mining substrate chain, so this
  table is what the block detail page surfaces as the real author. The
  block_hash column also doubles as the search index for substrate-block-hash
  lookups (which differ from the EVM-shaped hash Blockscout indexes).
  """

  use Explorer.Schema

  import Ecto.Query

  @primary_key {:block_number, :integer, autogenerate: false}
  @schema_prefix "roko"
  schema "block_authors" do
    field(:block_hash, :binary)
    field(:author_index, :integer)
    field(:author_stash, :binary)
    field(:slot, :integer)
    field(:recorded_at, :utc_datetime_usec)
  end

  @doc "Author + slot info for a single block."
  def by_block_query(block_number) when is_integer(block_number) do
    from(b in __MODULE__, where: b.block_number == ^block_number, limit: 1)
  end

  @doc "Reverse-lookup: substrate block hash → block number (for search)."
  def by_substrate_hash_query(hash_bytes) when is_binary(hash_bytes) do
    from(b in __MODULE__, where: b.block_hash == ^hash_bytes, limit: 1)
  end

  @doc "Aggregate: blocks authored by each validator over a recent window."
  def authored_counts_query(since_block) when is_integer(since_block) do
    from(b in __MODULE__,
      where: b.block_number >= ^since_block and not is_nil(b.author_stash),
      group_by: b.author_stash,
      select: {b.author_stash, count(b.block_number)},
      order_by: [desc: count(b.block_number)]
    )
  end
end
