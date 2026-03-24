defmodule Explorer.Repo.Migrations.AddAddressIdsToInternalTransactions do
  use Ecto.Migration

  def change do
    alter table(:internal_transactions) do
      add(:from_address_id, :bigint)
      add(:to_address_id, :bigint)
      add(:created_contract_address_id, :bigint)
    end
  end
end
