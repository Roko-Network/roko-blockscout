defmodule BlockScoutWeb.TemporalQualitySampler do
  @moduledoc """
  Temporal quality history with both in-memory (recent) and DB (long-term) storage.

  In-memory: records every consensus-time API call (up to 14,400 samples / ~24h).
  DB: persists one sample per hour via `persist_hourly/5` for long-term charting.
  """

  alias Explorer.Chain.TemporalQualitySample
  alias Explorer.Repo

  @max_memory_samples 14_400
  @hourly_interval_ms 3_600_000

  # --- In-memory (recent) ---

  def record_sample(quality, converged, peer_count, watermark) do
    now_ms = System.system_time(:millisecond)

    sample = %{
      timestamp: now_ms,
      quality: quality,
      converged: converged,
      peer_count: peer_count,
      watermark: watermark
    }

    samples = get_memory_samples()
    updated = samples ++ [sample]

    pruned =
      if length(updated) > @max_memory_samples do
        Enum.drop(updated, length(updated) - @max_memory_samples)
      else
        updated
      end

    Application.put_env(:block_scout_web, :temporal_quality_samples, pruned)

    # Persist hourly to DB
    maybe_persist_hourly(quality, converged, peer_count, watermark)
  end

  def get_history do
    get_memory_samples()
  end

  defp get_memory_samples do
    Application.get_env(:block_scout_web, :temporal_quality_samples, [])
  end

  # --- DB persistence (hourly) ---

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

  defp maybe_persist_hourly(quality, converged, peer_count, watermark) do
    last_persist = Application.get_env(:block_scout_web, :temporal_last_persist_ms, 0)
    now_ms = System.system_time(:millisecond)

    if now_ms - last_persist >= @hourly_interval_ms do
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
