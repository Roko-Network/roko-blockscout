defmodule BlockScoutWeb.API.V2.SubstrateControllerTest do
  use BlockScoutWeb.ConnCase

  describe "GET /api/v2/substrate/extrinsics/recent" do
    test "rejects unsupported extrinsic classes", %{conn: conn} do
      response =
        conn
        |> get("/api/v2/substrate/extrinsics/recent?extrinsic_class=System")
        |> json_response(400)

      assert response == %{
               "error" => "invalid extrinsic_class; expected Signed, Inherent, or Unsigned"
             }
    end
  end
end
