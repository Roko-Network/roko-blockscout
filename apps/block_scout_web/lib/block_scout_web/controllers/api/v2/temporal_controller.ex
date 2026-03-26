defmodule BlockScoutWeb.API.V2.TemporalController do
  @moduledoc """
  Controller for Roko Network temporal transaction data endpoints.

  Proxies JSON-RPC calls to the configured Roko node and returns the results
  in a format suitable for frontend consumption.

  Endpoints:
  - GET /api/v2/temporal/watermark - Current temporal watermark
  - GET /api/v2/temporal/consensus-time - Mesh consensus time and quality
  - GET /api/v2/temporal/queue-stats - Fee-priority queue statistics
  - GET /api/v2/temporal/transactions/:transaction_hash_param/timestamp - Canonical nanosecond timestamp for a transaction
  """

  use BlockScoutWeb, :controller

  require Logger

  @doc """
  Returns the current temporal watermark (block number + timestamp).

  Proxies `temporal_getWatermarkInfo` to the Roko node.
  """
  @spec watermark(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def watermark(conn, _params) do
    case rpc_call("temporal_getWatermarkInfo", []) do
      {:ok, result} -> json(conn, result)
      {:error, reason} -> conn |> put_status(502) |> json(%{error: reason})
    end
  end

  @doc """
  Returns the current mesh consensus time, quality score, and convergence state.

  Proxies `temporal_getConsensusTime` to the Roko node.
  """
  @spec consensus_time(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def consensus_time(conn, _params) do
    case rpc_call("temporal_getConsensusTime", []) do
      {:ok, result} ->
        # Record sample for quality chart history
        quality = result["timeQuality"] || 0
        converged = result["convergenceState"] == "Converged"
        peer_count = result["peerCount"] || 0
        BlockScoutWeb.TemporalQualitySampler.record_sample(quality, converged, peer_count, 0)
        json(conn, result)

      {:error, reason} ->
        conn |> put_status(502) |> json(%{error: reason})
    end
  end

  @doc """
  Returns fee-priority queue statistics including depth and wait-time percentiles.

  Proxies `temporal_getQueueStats` to the Roko node.
  """
  @spec queue_stats(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def queue_stats(conn, _params) do
    case rpc_call("temporal_getQueueStats", []) do
      {:ok, result} -> json(conn, result)
      {:error, reason} -> conn |> put_status(502) |> json(%{error: reason})
    end
  end

  @doc """
  Returns the canonical nanosecond timestamp for a specific transaction hash.

  Proxies `temporal_getTransactionTimestamp` to the Roko node.
  """
  @spec transaction_timestamp(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def transaction_timestamp(conn, %{"transaction_hash_param" => tx_hash}) do
    case rpc_call("temporal_getTransactionTimestamp", [tx_hash]) do
      {:ok, result} -> json(conn, result)
      {:error, reason} -> conn |> put_status(502) |> json(%{error: reason})
    end
  end

  @doc """
  Returns the temporal metadata for a specific block number.

  Proxies `temporal_getBlockMetadata` to the Roko node.
  Returns the block's nanosecond-precision temporal timestamp.
  """
  @spec block_metadata(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def block_metadata(conn, %{"block_number_param" => block_number_str}) do
    case Integer.parse(block_number_str) do
      {block_number, _} ->
        case rpc_call("temporal_getBlockMetadata", [block_number]) do
          {:ok, result} -> json(conn, result)
          {:error, reason} -> conn |> put_status(502) |> json(%{error: reason})
        end

      :error ->
        conn |> put_status(400) |> json(%{error: "invalid block number"})
    end
  end

  @doc """
  Returns time quality history for chart display.

  Returns up to 24 hours of samples collected every ~6 seconds.
  Each sample contains: timestamp (ms), quality (0-10000), converged (bool),
  peer_count, and watermark.
  """
  @spec quality_chart(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def quality_chart(conn, params) do
    hours = case Integer.parse(params["hours"] || "720") do
      {h, _} when h > 0 and h <= 8760 -> h
      _ -> 720
    end

    # DB samples (hourly, long-term) + in-memory samples (per-request, recent)
    db_samples = BlockScoutWeb.TemporalQualitySampler.get_db_history(hours)
    recent_samples = BlockScoutWeb.TemporalQualitySampler.get_history()

    # Merge: DB first, then recent (avoiding duplicates by timestamp)
    db_max_ts = case List.last(db_samples) do
      %{timestamp: ts} -> ts
      _ -> 0
    end

    merged = db_samples ++ Enum.filter(recent_samples, fn s -> s.timestamp > db_max_ts end)

    json(conn, %{chart_data: merged, db_samples: length(db_samples), recent_samples: length(recent_samples)})
  end

  @doc """
  Returns recent wait times from the fee-priority queue.

  Proxies `temporal_getRecentWaitTimes` to the Roko node.
  """
  @spec recent_wait_times(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def recent_wait_times(conn, _params) do
    case rpc_call("temporal_getRecentWaitTimes", []) do
      {:ok, result} -> json(conn, result)
      {:error, reason} -> conn |> put_status(502) |> json(%{error: reason})
    end
  end

  # Makes a JSON-RPC POST request to the configured Roko node endpoint.
  # Returns {:ok, result} on success or {:error, reason_string} on failure.
  @spec rpc_call(String.t(), list()) :: {:ok, term()} | {:error, String.t()}
  defp rpc_call(method, params) do
    url = rpc_url()
    body = Jason.encode!(%{jsonrpc: "2.0", method: method, params: params, id: 1})
    headers = [{"Content-Type", "application/json"}]

    case HTTPoison.post(url, body, headers, recv_timeout: 10_000, timeout: 15_000) do
      {:ok, %HTTPoison.Response{status_code: 200, body: response_body}} ->
        parse_rpc_response(response_body)

      {:ok, %HTTPoison.Response{status_code: code}} ->
        {:error, "upstream HTTP #{code}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.warning("Temporal RPC call to #{url} failed: #{inspect(reason)}")
        {:error, to_string(reason)}
    end
  end

  @spec parse_rpc_response(String.t()) :: {:ok, term()} | {:error, String.t()}
  defp parse_rpc_response(body) do
    case Jason.decode(body) do
      {:ok, %{"result" => result}} ->
        {:ok, result}

      {:ok, %{"error" => %{"message" => message}}} ->
        {:error, message}

      {:ok, %{"error" => error}} ->
        {:error, inspect(error)}

      {:error, _} ->
        {:error, "invalid JSON response from upstream"}
    end
  end

  @spec rpc_url() :: String.t()
  defp rpc_url do
    Application.get_env(:block_scout_web, :roko_rpc_url) ||
      System.get_env("ETHEREUM_JSONRPC_HTTP_URL") ||
      "http://localhost:8545"
  end
end
