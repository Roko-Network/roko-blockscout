defmodule BlockScoutWeb.TemporalQualitySampler do
  @moduledoc """
  Simple in-memory temporal quality history using Application env.
  Samples are recorded on each consensus-time API call.
  """

  @max_samples 14_400

  def record_sample(quality, converged, peer_count, watermark) do
    now_ms = System.system_time(:millisecond)

    sample = %{
      timestamp: now_ms,
      quality: quality,
      converged: converged,
      peer_count: peer_count,
      watermark: watermark
    }

    samples = get_samples()
    updated = samples ++ [sample]

    pruned =
      if length(updated) > @max_samples do
        Enum.drop(updated, length(updated) - @max_samples)
      else
        updated
      end

    Application.put_env(:block_scout_web, :temporal_quality_samples, pruned)
  end

  def get_history do
    get_samples()
  end

  defp get_samples do
    Application.get_env(:block_scout_web, :temporal_quality_samples, [])
  end
end
