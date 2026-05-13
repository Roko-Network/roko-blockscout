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
  - GET /api/v2/substrate/validators/:stash/pwroko-history (alias)
  - GET /api/v2/substrate/eras
  - GET /api/v2/substrate/slashing
  - GET /api/v2/substrate/pwroko/recent

  Endpoints added in Sprint 4 (S4-T6/T7/T8):
  - GET /api/v2/substrate/eras/:n
  - GET /api/v2/substrate/eras/:n/slashes
  - GET /api/v2/substrate/accounts/:address_param/pwroko-history
  - GET /api/v2/substrate/validators/:stash/clock-attestation
  """

  use BlockScoutWeb, :controller

  require Logger

  alias Explorer.Repo

  alias Explorer.Chain.{
    RokoEraSummary,
    RokoPwrokoTransfer,
    RokoSlashingEvent,
    RokoTimesyncViolation,
    RokoValidatorRegistry
  }

  alias BlockScoutWeb.Substrate.StorageKey

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

  @doc """
  pwROKO transfer history for any account (either side of the transfer).

  Sprint 4 / S4-T7: lives at `/accounts/:address_param/pwroko-history`. The
  legacy `/validators/:stash/pwroko-history` route still points here for
  backwards compatibility (the old action name is kept as a thin alias).
  """
  @spec account_pwroko_history(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def account_pwroko_history(conn, params) do
    limit = parse_limit(params["limit"], 100, 500)
    raw = params["address_param"] || params["stash"]

    case decode_stash(raw) do
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

  @doc "Alias kept so the legacy `/validators/:stash/pwroko-history` route keeps working."
  @spec validator_pwroko_history(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def validator_pwroko_history(conn, params), do: account_pwroko_history(conn, params)

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

  @doc "Single era summary by era_index."
  @spec era_detail(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def era_detail(conn, %{"n" => n_str}) do
    case Integer.parse(n_str) do
      {n, _} when n >= 0 ->
        case Repo.one(RokoEraSummary.by_index_query(n)) do
          nil -> conn |> put_status(404) |> json(%{error: "era not found"})
          era -> json(conn, serialize_era(era))
        end

      _ ->
        conn |> put_status(400) |> json(%{error: "invalid era index"})
    end
  end

  @doc "Slashing events that occurred during a given era."
  @spec era_slashes(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def era_slashes(conn, %{"n" => n_str} = params) do
    limit = parse_limit(params["limit"], 100, 500)

    case Integer.parse(n_str) do
      {n, _} when n >= 0 ->
        # The era summary row must exist for us to return slashes — keeps
        # this endpoint's 404 semantics consistent with /eras/:n.
        case Repo.one(RokoEraSummary.by_index_query(n)) do
          nil ->
            conn |> put_status(404) |> json(%{error: "era not found"})

          _ ->
            rows =
              RokoSlashingEvent.by_era_query(n, limit)
              |> Repo.all()
              |> Enum.map(&serialize_slash/1)

            json(conn, %{items: rows})
        end

      _ ->
        conn |> put_status(400) |> json(%{error: "invalid era index"})
    end
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

  @doc """
  Returns the validator's self-attested clock hardware report (Sprint 4 / S4-T8).

  Reads `timeSync.clockAttestations(stash)` via `state_getStorage` on the
  substrate RPC, then SCALE-decodes the `ClockAttestation` record. 404 when
  the validator has not yet submitted an attestation.
  """
  @spec validator_clock_attestation(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def validator_clock_attestation(conn, %{"stash" => stash_hex}) do
    case decode_stash(stash_hex) do
      :error ->
        conn |> put_status(400) |> json(%{error: "invalid stash hex"})

      {:ok, bytes} ->
        storage_key =
          "0x" <>
            Base.encode16(
              StorageKey.map_key("TimeSync", "ClockAttestations", bytes),
              case: :lower
            )

        case rpc_call("state_getStorage", [storage_key]) do
          {:ok, nil} ->
            conn |> put_status(404) |> json(%{error: "no attestation submitted"})

          {:ok, "0x"} ->
            conn |> put_status(404) |> json(%{error: "no attestation submitted"})

          {:ok, hex_value} when is_binary(hex_value) ->
            case decode_clock_attestation(hex_value) do
              {:ok, attestation} -> json(conn, attestation)
              {:error, reason} -> conn |> put_status(502) |> json(%{error: reason})
            end

          {:error, reason} ->
            conn |> put_status(502) |> json(%{error: reason})
        end
    end
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

  # Accepts both H160 (20-byte, the Roko default) and AccountId32 (32-byte) so
  # this controller works regardless of which account type the underlying
  # storage uses. The `roko.validator_registry` table is currently populated
  # with H160 stashes; older substrate tooling sometimes encodes them padded
  # to 32 bytes — both are accepted.
  defp decode_stash(hex_str) when is_binary(hex_str) do
    case Base.decode16(hex_str, case: :mixed) do
      {:ok, bytes} when byte_size(bytes) in [20, 32] -> {:ok, bytes}
      _ -> :error
    end
  end

  defp decode_stash(_), do: :error

  # --- SCALE decoding of ClockAttestation ----------------------------------

  # ClockAttestation layout (see node/primitives/src/timesync.rs):
  #   detected_source            : u8  (ClockSource enum variant)
  #   root_distance_ns           : u64 little-endian
  #   calibration_window_blocks  : u32 little-endian
  #   attested_at_block          : u32 little-endian
  defp decode_clock_attestation("0x" <> hex), do: decode_clock_attestation(hex)

  defp decode_clock_attestation(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok,
       <<source_byte, root_distance_ns::little-unsigned-integer-size(64),
         calibration_window_blocks::little-unsigned-integer-size(32),
         attested_at_block::little-unsigned-integer-size(32), _rest::binary>>} ->
        {:ok,
         %{
           detected_source: clock_source_label(source_byte),
           detected_source_index: source_byte,
           root_distance_ns: root_distance_ns,
           calibration_window_blocks: calibration_window_blocks,
           attested_at_block: attested_at_block
         }}

      _ ->
        {:error, "could not decode ClockAttestation"}
    end
  end

  defp clock_source_label(0), do: "Pps"
  defp clock_source_label(1), do: "Timebeat"
  defp clock_source_label(2), do: "Phc"
  defp clock_source_label(3), do: "NtpSynced"
  defp clock_source_label(4), do: "SystemOnly"
  defp clock_source_label(_), do: "Unknown"

  # --- JSON-RPC passthrough (mirrors TemporalController.rpc_call/2) ---------

  @spec rpc_call(String.t(), list()) :: {:ok, term()} | {:error, String.t()}
  defp rpc_call(method, params) do
    url = rpc_url()
    body = Jason.encode!(%{jsonrpc: "2.0", method: method, params: params, id: 1})
    headers = [{"Content-Type", "application/json"}]

    case HTTPoison.post(url, body, headers, recv_timeout: 10_000, timeout: 15_000) do
      {:ok, %HTTPoison.Response{status_code: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, %{"result" => result}} -> {:ok, result}
          {:ok, %{"error" => %{"message" => message}}} -> {:error, message}
          {:ok, %{"error" => error}} -> {:error, inspect(error)}
          _ -> {:error, "invalid JSON response from upstream"}
        end

      {:ok, %HTTPoison.Response{status_code: code}} ->
        {:error, "upstream HTTP #{code}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.warning("Substrate RPC call to #{url} failed: #{inspect(reason)}")
        {:error, to_string(reason)}
    end
  end

  defp rpc_url do
    Application.get_env(:block_scout_web, :roko_rpc_url) ||
      System.get_env("ETHEREUM_JSONRPC_HTTP_URL") ||
      "http://localhost:8545"
  end

  defp parse_limit(nil, default, _max), do: default

  defp parse_limit(str, default, max) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} when n > 0 and n <= max -> n
      _ -> default
    end
  end

  defp parse_limit(_, default, _max), do: default
end
