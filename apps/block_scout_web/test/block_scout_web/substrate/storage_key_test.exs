defmodule BlockScoutWeb.Substrate.StorageKeyTest do
  @moduledoc """
  Verifies the pure-Elixir xxhash64 / twox_128 / twox_64_concat helpers
  against substrate-canonical test vectors. The reference values come from
  polkadot.js (`util-crypto`) — any change here that breaks these breaks
  every substrate-storage passthrough endpoint.
  """

  use ExUnit.Case, async: true

  alias BlockScoutWeb.Substrate.StorageKey

  test "xxhash64 matches reference vectors (seed=0)" do
    assert StorageKey.xxhash64("") == 0xEF46_DB37_51D8_E999
    assert StorageKey.xxhash64("Hello!") == 0xA8A9_8986_7030_00D5
  end

  test "twox128 matches substrate canonical prefixes" do
    assert StorageKey.twox128("System") ==
             Base.decode16!("26AA394EEA5630E07C48AE0C9558CEF7", case: :mixed)

    assert StorageKey.twox128("Account") ==
             Base.decode16!("B99D880EC681799C0CF30E8886371DA9", case: :mixed)

    assert StorageKey.twox128("TimeSync") ==
             Base.decode16!("3096F004EB09F66D88FC544E437C811E", case: :mixed)

    assert StorageKey.twox128("ClockAttestations") ==
             Base.decode16!("CBAE6AB56776C35460705418E3A17079", case: :mixed)
  end

  test "twox64_concat appends the raw key after the 8-byte hash" do
    key = <<0xAA, 0xBB, 0xCC>>
    out = StorageKey.twox64_concat(key)
    assert byte_size(out) == 8 + byte_size(key)
    assert binary_part(out, 8, 3) == key
  end

  test "map_key builds the canonical timeSync.clockAttestations storage key" do
    account = Base.decode16!("F24FF3A9CF04C71DBC94D0B566F7A27B94566CAC", case: :mixed)

    expected =
      Base.decode16!(
        "3096F004EB09F66D88FC544E437C811E" <>
          "CBAE6AB56776C35460705418E3A17079" <>
          "4A6BB7C01D316509" <>
          "F24FF3A9CF04C71DBC94D0B566F7A27B94566CAC",
        case: :mixed
      )

    assert StorageKey.map_key("TimeSync", "ClockAttestations", account) == expected
  end
end
