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
end
