defmodule BlockScoutWeb.API.V2.TemporalControllerTest do
  use BlockScoutWeb.ConnCase, async: false

  @watermark_method "temporal_getWatermarkInfo"
  @consensus_time_method "temporal_getConsensusTime"
  @queue_stats_method "temporal_getQueueStats"
  @transaction_timestamp_method "temporal_getTransactionTimestamp"

  setup do
    bypass = Bypass.open()

    original_rpc_url = Application.get_env(:block_scout_web, :roko_rpc_url)

    Application.put_env(:block_scout_web, :roko_rpc_url, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      Application.put_env(:block_scout_web, :roko_rpc_url, original_rpc_url)
    end)

    %{bypass: bypass}
  end

  describe "GET /api/v2/temporal/watermark" do
    test "returns watermark data on success", %{conn: conn, bypass: bypass} do
      watermark_result = %{
        "block_number" => 42,
        "timestamp_ns" => 1_711_234_567_000_000_000
      }

      Bypass.expect_once(bypass, "POST", "/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert {:ok, %{"method" => @watermark_method, "params" => []}} = Jason.decode(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => watermark_result}))
      end)

      response = get(conn, "/api/v2/temporal/watermark")

      assert json_response(response, 200) == watermark_result
    end

    test "returns 502 when node returns JSON-RPC error", %{conn: conn, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "error" => %{"code" => -32601, "message" => "Method not found"}})
        )
      end)

      response = get(conn, "/api/v2/temporal/watermark")

      assert %{"error" => _} = json_response(response, 502)
    end

    test "returns 502 when node is unreachable", %{conn: conn, bypass: bypass} do
      Bypass.down(bypass)

      response = get(conn, "/api/v2/temporal/watermark")

      assert %{"error" => _} = json_response(response, 502)

      Bypass.up(bypass)
    end

    test "returns 502 on non-200 HTTP status", %{conn: conn, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/", fn conn ->
        Plug.Conn.resp(conn, 503, "Service Unavailable")
      end)

      response = get(conn, "/api/v2/temporal/watermark")

      assert %{"error" => _} = json_response(response, 502)
    end
  end

  describe "GET /api/v2/temporal/consensus-time" do
    test "returns consensus time data on success", %{conn: conn, bypass: bypass} do
      consensus_result = %{
        "time_ns" => 1_711_234_567_000_000_000,
        "quality" => 0.98,
        "converged" => true
      }

      Bypass.expect_once(bypass, "POST", "/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert {:ok, %{"method" => @consensus_time_method, "params" => []}} = Jason.decode(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => consensus_result}))
      end)

      response = get(conn, "/api/v2/temporal/consensus-time")

      assert json_response(response, 200) == consensus_result
    end

    test "returns 502 when node returns JSON-RPC error", %{conn: conn, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "error" => %{"code" => -32601, "message" => "Method not found"}})
        )
      end)

      response = get(conn, "/api/v2/temporal/consensus-time")

      assert %{"error" => _} = json_response(response, 502)
    end
  end

  describe "GET /api/v2/temporal/queue-stats" do
    test "returns queue stats on success", %{conn: conn, bypass: bypass} do
      queue_result = %{
        "depth" => 15,
        "wait_p50_ms" => 120,
        "wait_p99_ms" => 450
      }

      Bypass.expect_once(bypass, "POST", "/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert {:ok, %{"method" => @queue_stats_method, "params" => []}} = Jason.decode(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => queue_result}))
      end)

      response = get(conn, "/api/v2/temporal/queue-stats")

      assert json_response(response, 200) == queue_result
    end

    test "returns 502 when node returns JSON-RPC error", %{conn: conn, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "error" => %{"code" => -32601, "message" => "Method not found"}})
        )
      end)

      response = get(conn, "/api/v2/temporal/queue-stats")

      assert %{"error" => _} = json_response(response, 502)
    end
  end

  describe "GET /api/v2/temporal/transactions/:transaction_hash_param/timestamp" do
    test "returns transaction timestamp on success", %{conn: conn, bypass: bypass} do
      tx_hash = "0x" <> String.duplicate("ab", 32)
      timestamp_result = %{"timestamp_ns" => 1_711_234_567_123_456_789}

      Bypass.expect_once(bypass, "POST", "/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert {:ok, %{"method" => @transaction_timestamp_method, "params" => [^tx_hash]}} = Jason.decode(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => timestamp_result}))
      end)

      response = get(conn, "/api/v2/temporal/transactions/#{tx_hash}/timestamp")

      assert json_response(response, 200) == timestamp_result
    end

    test "returns 502 when node returns JSON-RPC error for unknown tx", %{conn: conn, bypass: bypass} do
      tx_hash = "0x" <> String.duplicate("cd", 32)

      Bypass.expect_once(bypass, "POST", "/", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "error" => %{"code" => -32000, "message" => "not found"}})
        )
      end)

      response = get(conn, "/api/v2/temporal/transactions/#{tx_hash}/timestamp")

      assert %{"error" => _} = json_response(response, 502)
    end

    test "passes transaction hash as RPC param", %{conn: conn, bypass: bypass} do
      tx_hash = "0x" <> String.duplicate("ff", 32)

      Bypass.expect_once(bypass, "POST", "/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["method"] == @transaction_timestamp_method
        assert decoded["params"] == [tx_hash]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{"timestamp_ns" => 0}}))
      end)

      get(conn, "/api/v2/temporal/transactions/#{tx_hash}/timestamp")
    end
  end
end
