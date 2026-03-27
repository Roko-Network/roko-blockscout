defmodule BlockScoutWeb.TemporalQualitySampler do
  @moduledoc """
  Temporal quality DB persistence.

  Persists one sample every 5 minutes to PostgreSQL for long-term charting.
  Triggered lazily on each consensus-time API call.
  """

  alias Explorer.Chain.TemporalQualitySample
  alias Explorer.Repo

  # Persist every 5 minutes
  @persist_interval_ms 300_000

  def record_sample(quality, converged, peer_count, watermark) do
    maybe_persist(quality, converged, peer_count, watermark)
  end

  def get_db_history(hours_back \\ 720) do
    try do
      TemporalQualitySample.history_query(hours_back)
      |> Repo.all()
      |> Enum.map(fn s ->
        %{
          timestamp: DateTime.to_unix(s.sampled_at, :millisecond),
          quality: s.time_quality,
          converged: s.is_converged,
          peer_count: s.peer_count,
          watermark: Decimal.to_integer(s.watermark),
          block_height: s.block_height
        }
      end)
    rescue
      _ -> []
    end
  end

  defp maybe_persist(quality, converged, peer_count, watermark) do
    last_persist = Application.get_env(:block_scout_web, :temporal_last_persist_ms, 0)
    now_ms = System.system_time(:millisecond)

    if now_ms - last_persist >= @persist_interval_ms do
      Application.put_env(:block_scout_web, :temporal_last_persist_ms, now_ms)

      block_height =
        try do
          case get_block_height() do
            {:ok, h} -> h
            _ -> 0
          end
        rescue
          _ -> 0
        end

      try do
        %TemporalQualitySample{}
        |> TemporalQualitySample.changeset(%{
          sampled_at: DateTime.utc_now(),
          time_quality: quality,
          is_converged: converged,
          peer_count: peer_count,
          watermark: watermark,
          block_height: block_height
        })
        |> Repo.insert()
      rescue
        _ -> :ok
      end
    end
  end

  defp get_block_height do
    url = rpc_url()
    body = Jason.encode!(%{jsonrpc: "2.0", method: "eth_blockNumber", params: [], id: 1})

    case HTTPoison.post(url, body, [{"Content-Type", "application/json"}],
           recv_timeout: 3_000,
           timeout: 3_000
         ) do
      {:ok, %{status_code: 200, body: resp}} ->
        case Jason.decode(resp) do
          {:ok, %{"result" => hex}} ->
            {height, _} = Integer.parse(String.replace_prefix(hex, "0x", ""), 16)
            {:ok, height}

          _ ->
            {:error, :parse}
        end

      _ ->
        {:error, :rpc}
    end
  end

  defp rpc_url do
    Application.get_env(:block_scout_web, :roko_rpc_url) ||
      System.get_env("ETHEREUM_JSONRPC_HTTP_URL") ||
      "http://localhost:8545"
  end
end
