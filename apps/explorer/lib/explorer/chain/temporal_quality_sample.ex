defmodule Explorer.Chain.TemporalQualitySample do
  @moduledoc """
  Hourly temporal time quality sample for the Roko Network time mesh.

  Records the mesh quality, convergence state, peer count, watermark,
  and block height at regular intervals for historical chart display.
  """

  use Explorer.Schema

  import Ecto.Query

  @primary_key {:id, :id, autogenerate: true}
  typed_schema "temporal_quality_samples" do
    field(:sampled_at, :utc_datetime_usec)
    field(:time_quality, :integer)
    field(:is_converged, :boolean)
    field(:peer_count, :integer)
    field(:watermark, :decimal)
    field(:block_height, :integer)
  end

  @required_fields ~w(sampled_at time_quality is_converged peer_count watermark block_height)a

  def changeset(struct, params \\ %{}) do
    struct
    |> cast(params, @required_fields)
    |> validate_required(@required_fields)
  end

  @doc """
  Returns all samples ordered by time within the given hours window.
  """
  def history_query(hours_back \\ 720) do
    cutoff = DateTime.add(DateTime.utc_now(), -hours_back * 3600, :second)

    from(s in __MODULE__,
      where: s.sampled_at >= ^cutoff,
      order_by: [asc: s.sampled_at]
    )
  end
end
