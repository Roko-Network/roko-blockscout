defmodule BlockScoutWeb.Substrate.StorageKey do
  @moduledoc """
  Helpers for building substrate `state_getStorage` keys client-side.

  The substrate runtime does not (yet) expose a typed Runtime API for
  `timeSync.clockAttestations`, so the controller has to compute the
  storage key the same way the runtime does:

      key = twox128("TimeSync") <> twox128("ClockAttestations") <> twox64_concat(account)

  with `Twox64Concat = xxhash64(seed=0) ++ key` for the map's key hasher.
  """

  use Bitwise

  @mask64 0xFFFF_FFFF_FFFF_FFFF
  @prime1 0x9E37_79B1_85EB_CA87
  @prime2 0xC2B2_AE3D_27D4_EB4F
  @prime3 0x1656_67B1_9E37_79F9
  @prime4 0x85EB_CA77_C2B2_AE63
  @prime5 0x27D4_EB2F_1656_67C5

  @doc """
  xxhash64 (seed = 0) of `data`, returned as an unsigned 64-bit integer.

  Implementation follows the canonical reference:
  https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md
  """
  @spec xxhash64(binary()) :: non_neg_integer()
  def xxhash64(data) when is_binary(data) do
    len = byte_size(data)

    {h, rest} =
      if len >= 32 do
        large_hash(data)
      else
        {(@prime5 + len) &&& @mask64, data}
      end

    h = if len >= 32, do: (h + len) &&& @mask64, else: h
    finalize_remaining(h, rest) |> avalanche()
  end

  @doc """
  xxhash64 returned as 8 little-endian bytes — the `twox_64` substrate primitive.
  """
  @spec twox64(binary()) :: binary()
  def twox64(data), do: <<xxhash64(data)::little-unsigned-integer-size(64)>>

  @doc """
  Two concatenated xxhash64 hashes (seeded with the bytes themselves twice; the
  substrate convention concatenates `twox64(data) ++ twox64_with_xor(data)`).

  Following the substrate primitive: `twox_128 = twox64(0, data) ++ twox64(1, data)`,
  where the seed argument is folded in by hashing `<<seed::little-64>> <> data`.
  In the canonical substrate impl, seeds are 0 and 1; both produce 8 bytes LE.
  """
  @spec twox128(binary()) :: binary()
  def twox128(data) do
    <<xxhash64_seeded(0, data)::little-unsigned-integer-size(64),
      xxhash64_seeded(1, data)::little-unsigned-integer-size(64)>>
  end

  @doc """
  `twox_64_concat(data) = twox64(data) ++ data` — the variable hasher used by
  pallet `StorageMap`s declared with `Twox64Concat`.
  """
  @spec twox64_concat(binary()) :: binary()
  def twox64_concat(data) when is_binary(data) do
    twox64(data) <> data
  end

  @doc """
  Build the storage key for a `StorageMap<_, Twox64Concat, K, V>` entry.

      iex> StorageKey.map_key("TimeSync", "ClockAttestations", <<0x01, 0x02>>)
      <<...>>
  """
  @spec map_key(String.t(), String.t(), binary()) :: binary()
  def map_key(pallet, storage_item, key_bytes) do
    twox128(pallet) <> twox128(storage_item) <> twox64_concat(key_bytes)
  end

  # ---------------------------------------------------------------------------
  # xxhash64 internals
  # ---------------------------------------------------------------------------

  defp xxhash64_seeded(seed, data) when is_integer(seed) and seed >= 0 do
    # Substrate's twox128 uses xxhash64 with the seed value as the seed,
    # not seed-bytes-prepended-to-data. The xxhash64 spec accepts a 64-bit
    # seed which is added into the initial accumulators.
    len = byte_size(data)

    {h, rest} =
      if len >= 32 do
        large_hash_seeded(data, seed)
      else
        {(seed + @prime5) &&& @mask64, data}
      end

    h = (h + len) &&& @mask64
    finalize_remaining(h, rest) |> avalanche()
  end

  defp large_hash(data), do: large_hash_seeded(data, 0)

  defp large_hash_seeded(data, seed) do
    v1 = (seed + @prime1 + @prime2) &&& @mask64
    v2 = (seed + @prime2) &&& @mask64
    v3 = seed
    v4 = (seed - @prime1) &&& @mask64

    {v1, v2, v3, v4, rest} = consume_32_lanes(data, v1, v2, v3, v4)

    h =
      rotl(v1, 1)
      |> add(rotl(v2, 7))
      |> add(rotl(v3, 12))
      |> add(rotl(v4, 18))

    h =
      h
      |> merge_round(v1)
      |> merge_round(v2)
      |> merge_round(v3)
      |> merge_round(v4)

    {h, rest}
  end

  defp consume_32_lanes(<<a::little-64, b::little-64, c::little-64, d::little-64, rest::binary>>, v1, v2, v3, v4) do
    consume_32_lanes(rest, round_lane(v1, a), round_lane(v2, b), round_lane(v3, c), round_lane(v4, d))
  end

  defp consume_32_lanes(rest, v1, v2, v3, v4), do: {v1, v2, v3, v4, rest}

  defp round_lane(acc, input) do
    acc = (acc + (input * @prime2 &&& @mask64)) &&& @mask64
    acc = rotl(acc, 31)
    (acc * @prime1) &&& @mask64
  end

  defp merge_round(h, val) do
    val = round_lane(0, val)
    h = bxor(h, val)
    ((h * @prime1) + @prime4) &&& @mask64
  end

  defp finalize_remaining(h, <<chunk::little-64, rest::binary>>) do
    k = round_lane(0, chunk)
    h = bxor(h, k)
    h = ((rotl(h, 27) * @prime1) + @prime4) &&& @mask64
    finalize_remaining(h, rest)
  end

  defp finalize_remaining(h, <<chunk::little-32, rest::binary>>) do
    h = bxor(h, (chunk * @prime1) &&& @mask64)
    h = ((rotl(h, 23) * @prime2) + @prime3) &&& @mask64
    finalize_remaining(h, rest)
  end

  defp finalize_remaining(h, <<byte, rest::binary>>) do
    h = bxor(h, (byte * @prime5) &&& @mask64)
    h = (rotl(h, 11) * @prime1) &&& @mask64
    finalize_remaining(h, rest)
  end

  defp finalize_remaining(h, <<>>), do: h

  defp avalanche(h) do
    h = bxor(h, h >>> 33)
    h = (h * @prime2) &&& @mask64
    h = bxor(h, h >>> 29)
    h = (h * @prime3) &&& @mask64
    bxor(h, h >>> 32)
  end

  defp add(a, b), do: (a + b) &&& @mask64

  defp rotl(x, n) do
    x = x &&& @mask64
    (((x <<< n) &&& @mask64) ||| (x >>> (64 - n))) &&& @mask64
  end
end
