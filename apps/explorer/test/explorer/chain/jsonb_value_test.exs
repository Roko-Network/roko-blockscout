defmodule Explorer.Chain.JSONBValueTest do
  use ExUnit.Case, async: true

  alias Explorer.Chain.{JSONBValue, RokoExtrinsic}

  describe "jsonb container compatibility" do
    test "loads, casts, and dumps JSON objects" do
      value = %{"variant" => "Immortal"}

      assert JSONBValue.load(value) == {:ok, value}
      assert JSONBValue.cast(value) == {:ok, value}
      assert JSONBValue.dump(value) == {:ok, value}
    end

    test "loads, casts, and dumps array-shaped Substrate enum values" do
      value = [%{"fields" => "0x02", "variant" => "Mortal6"}]

      assert JSONBValue.load(value) == {:ok, value}
      assert JSONBValue.cast(value) == {:ok, value}
      assert JSONBValue.dump(value) == {:ok, value}
    end

    test "rejects scalar JSON values" do
      for value <- ["Mortal6", 6, true] do
        assert JSONBValue.load(value) == :error
        assert JSONBValue.cast(value) == :error
        assert JSONBValue.dump(value) == :error
      end
    end

    test "RokoExtrinsic schema loads an array-shaped signed era" do
      era = [%{"fields" => "0x02", "variant" => "Mortal6"}]

      assert %RokoExtrinsic{era: ^era} =
               Ecto.embedded_load(RokoExtrinsic, %{"era" => era}, :json)
    end

    test "RokoExtrinsic schema leaves a nullable era unset" do
      assert %RokoExtrinsic{era: nil} =
               Ecto.embedded_load(RokoExtrinsic, %{"era" => nil}, :json)
    end
  end

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
