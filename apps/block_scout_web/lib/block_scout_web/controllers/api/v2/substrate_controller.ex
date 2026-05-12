defmodule BlockScoutWeb.API.V2.SubstrateController do
  @moduledoc """
  Substrate-native endpoints surfacing data indexed by `roko-indexer-sidecar`
  (a separate Rust binary that subscribes to finalized headers, decodes
  pallet events, and writes rows into the `roko.*` schema in this same
  Postgres instance).

  This controller is the read side of that pipeline. All queries hit the
  `roko` schema; no controller in this fork writes to it.

  Endpoints (Sprint 2 / TICKET-18 initial set):
  - GET /api/v2/substrate/validators
  - GET /api/v2/substrate/validators/:stash
  - GET /api/v2/substrate/validators/:stash/violations
  - GET /api/v2/substrate/validators/:stash/pwroko-history
  - GET /api/v2/substrate/eras
  - GET /api/v2/substrate/slashing
  - GET /api/v2/substrate/pwroko/recent
  """

  use BlockScoutWeb, :controller

  alias Explorer.Repo

  alias Explorer.Chain.{
    RokoEraSummary,
    RokoPwrokoTransfer,
    RokoSlashingEvent,
    RokoTimesyncViolation,
    RokoValidatorRegistry
  }

  @doc "List active validators."
  @spec validators(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def validators(conn, _params) do
    rows =
      RokoValidatorRegistry.active_query()
      |> Repo.all()
      |> Enum.map(&serialize_validator/1)

    json(conn, %{items: rows})
  end

  @doc "Single validator by stash hex."
  @spec validator(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def validator(conn, %{"stash" => stash_hex}) do
    case decode_stash(stash_hex) do
      {:ok, bytes} ->
        case Repo.one(RokoValidatorRegistry.by_stash_query(bytes)) do
          nil -> conn |> put_status(404) |> json(%{error: "validator not found"})
          v -> json(conn, serialize_validator(v))
        end

      :error ->
        conn |> put_status(400) |> json(%{error: "invalid stash hex"})
    end
  end

  @doc "Violations for a validator (by stash)."
  @spec validator_violations(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def validator_violations(conn, %{"stash" => stash_hex} = params) do
    limit = parse_limit(params["limit"], 100, 500)

    case decode_stash(stash_hex) do
      {:ok, bytes} ->
        rows =
          RokoTimesyncViolation.by_stash_query(bytes, limit)
          |> Repo.all()
          |> Enum.map(&serialize_violation/1)

        json(conn, %{items: rows})

      :error ->
        conn |> put_status(400) |> json(%{error: "invalid stash hex"})
    end
  end

  @doc "pwROKO transfer history for an account (either side)."
  @spec validator_pwroko_history(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def validator_pwroko_history(conn, %{"stash" => stash_hex} = params) do
    limit = parse_limit(params["limit"], 100, 500)

    case decode_stash(stash_hex) do
      {:ok, bytes} ->
        rows =
          RokoPwrokoTransfer.for_account_query(bytes, limit)
          |> Repo.all()
          |> Enum.map(&serialize_pwroko/1)

        json(conn, %{items: rows})

      :error ->
        conn |> put_status(400) |> json(%{error: "invalid account hex"})
    end
  end

  @doc "Recent eras."
  @spec eras(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def eras(conn, params) do
    limit = parse_limit(params["limit"], 20, 100)

    rows =
      RokoEraSummary.recent_query(limit)
      |> Repo.all()
      |> Enum.map(&serialize_era/1)

    json(conn, %{items: rows})
  end

  @doc "Recent slashing events (across all validators)."
  @spec slashing(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def slashing(conn, params) do
    limit = parse_limit(params["limit"], 50, 500)

    rows =
      RokoSlashingEvent.recent_query(limit)
      |> Repo.all()
      |> Enum.map(&serialize_slash/1)

    json(conn, %{items: rows})
  end

  @doc "Recent pwROKO transfers (across all accounts)."
  @spec pwroko_recent(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def pwroko_recent(conn, params) do
    kind = params["kind"]
    limit = parse_limit(params["limit"], 100, 500)

    query =
      if is_binary(kind) and kind != "" do
        RokoPwrokoTransfer.by_event_kind_query(kind, limit)
      else
        import Ecto.Query
        from(t in RokoPwrokoTransfer,
          order_by: [desc: t.block_number, desc: t.id],
          limit: ^limit
        )
      end

    rows = query |> Repo.all() |> Enum.map(&serialize_pwroko/1)
    json(conn, %{items: rows})
  end

  # --- Serializers ----------------------------------------------------------

  defp serialize_validator(v) do
    %{
      stash: hex(v.stash),
      controller: hex(v.controller),
      authority_index: v.authority_index,
      session_keys: v.session_keys,
      commission_pct: v.commission_pct,
      bonded_amount: decimal_to_string(v.bonded_amount),
      status: v.status,
      first_seen_block: v.first_seen_block,
      last_updated_block: v.last_updated_block
    }
  end

  defp serialize_violation(v) do
    %{
      id: v.id,
      block_number: v.block_number,
      block_hash: hex(v.block_hash),
      extrinsic_index: v.extrinsic_index,
      stash: hex(v.stash),
      authority_index: v.authority_index,
      kind: v.kind,
      severity: v.severity,
      detail: v.detail,
      escalated: v.escalated,
      recorded_at: v.recorded_at
    }
  end

  defp serialize_pwroko(t) do
    %{
      id: t.id,
      block_number: t.block_number,
      block_hash: hex(t.block_hash),
      extrinsic_index: t.extrinsic_index,
      event_kind: t.event_kind,
      from_account: hex(t.from_account),
      to_account: hex(t.to_account),
      amount: decimal_to_string(t.amount),
      backing_amount: decimal_to_string(t.backing_amount),
      extra: t.extra
    }
  end

  defp serialize_era(e) do
    %{
      era_index: e.era_index,
      start_block: e.start_block,
      end_block: e.end_block,
      start_session: e.start_session,
      end_session: e.end_session,
      validator_count: e.validator_count,
      total_stake: decimal_to_string(e.total_stake),
      validator_payout: decimal_to_string(e.validator_payout),
      remainder_payout: decimal_to_string(e.remainder_payout),
      slashed_count: e.slashed_count,
      slashed_total: decimal_to_string(e.slashed_total),
      finalized: e.finalized,
      finalized_at_block: e.finalized_at_block
    }
  end

  defp serialize_slash(s) do
    %{
      id: s.id,
      era_index: s.era_index,
      block_number: s.block_number,
      block_hash: hex(s.block_hash),
      stash: hex(s.stash),
      offence_kind: s.offence_kind,
      slash_amount: decimal_to_string(s.slash_amount),
      reporters: Enum.map(s.reporters || [], &hex/1),
      detail: s.detail,
      recorded_at: s.recorded_at
    }
  end

  # --- Helpers --------------------------------------------------------------

  defp hex(nil), do: nil
  defp hex(<<bytes::binary>>), do: "0x" <> Base.encode16(bytes, case: :lower)

  defp decimal_to_string(nil), do: nil
  defp decimal_to_string(%Decimal{} = d), do: Decimal.to_string(d)
  defp decimal_to_string(other), do: to_string(other)

  defp decode_stash("0x" <> hex_str), do: decode_stash(hex_str)

  defp decode_stash(hex_str) when is_binary(hex_str) do
    case Base.decode16(hex_str, case: :mixed) do
      {:ok, bytes} when byte_size(bytes) == 32 -> {:ok, bytes}
      _ -> :error
    end
  end

  defp decode_stash(_), do: :error

  defp parse_limit(nil, default, _max), do: default

  defp parse_limit(str, default, max) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} when n > 0 and n <= max -> n
      _ -> default
    end
  end

  defp parse_limit(_, default, _max), do: default
end
