defmodule Explorer.Chain.JSONBValue do
  @moduledoc """
  Ecto type for a PostgreSQL `jsonb` value whose top level may be an object
  or an array.

  Ecto's built-in `:map` type accepts JSON objects but rejects arrays while
  loading query results. Substrate metadata represents some enum values
  (including signed transaction eras) as a one-element JSON array, so these
  columns need to preserve either container shape.
  """

  use Ecto.Type

  @type t :: map() | list()

  @impl Ecto.Type
  def type, do: :map

  @impl Ecto.Type
  def cast(value) when is_map(value) or is_list(value), do: {:ok, value}
  def cast(_value), do: :error

  @impl Ecto.Type
  def load(value) when is_map(value) or is_list(value), do: {:ok, value}
  def load(_value), do: :error

  @impl Ecto.Type
  def dump(value) when is_map(value) or is_list(value), do: {:ok, value}
  def dump(_value), do: :error
end
