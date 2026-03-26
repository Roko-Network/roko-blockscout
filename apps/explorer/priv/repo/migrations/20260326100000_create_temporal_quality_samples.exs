defmodule Explorer.Repo.Migrations.CreateTemporalQualitySamples do
  use Ecto.Migration

  def change do
    create table(:temporal_quality_samples, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:sampled_at, :utc_datetime_usec, null: false)
      add(:time_quality, :integer, null: false)
      add(:is_converged, :boolean, null: false, default: false)
      add(:peer_count, :integer, null: false, default: 0)
      add(:watermark, :numeric, precision: 39, scale: 0, null: false, default: 0)
      add(:block_height, :bigint, null: false, default: 0)
    end

    create(index(:temporal_quality_samples, [:sampled_at]))
  end
end
