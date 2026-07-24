defmodule Explorer.Chain.RokoExtrinsicTest do
  use ExUnit.Case, async: true

  alias Explorer.Chain.RokoExtrinsic

  describe "recent_query/1" do
    test "composes class, pallet, method, and cursor filters" do
      query =
        RokoExtrinsic.recent_query(
          extrinsic_class: "Signed",
          pallet: "Staking",
          method: "payout_stakers",
          before_block: 28_964,
          before_index: 3,
          limit: 5
        )

      params =
        query.wheres
        |> Enum.flat_map(& &1.params)
        |> Enum.map(&elem(&1, 0))

      assert "Signed" in params
      assert "Staking" in params
      assert "payout_stakers" in params
      assert 28_964 in params
      assert 3 in params
      assert query.limit.params == [{5, :integer}]
    end

    test "preserves the unfiltered feed when no class is requested" do
      query = RokoExtrinsic.recent_query(limit: 10)

      assert query.wheres == []
      assert query.limit.params == [{10, :integer}]
    end
  end
end
