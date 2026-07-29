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

  import Ecto.Query, only: [from: 2]

  alias Explorer.Repo

  alias Explorer.Chain.{
    RokoBlockAuthor,
    RokoEraSummary,
    RokoEvent,
    RokoExtrinsic,
    RokoPwrokoTransfer,
    RokoSlashingEvent,
    RokoTimesyncViolation,
    RokoValidatorRegistry
  }

  alias BlockScoutWeb.Substrate.StorageKey

  @extrinsic_classes ~w(Signed Inherent Unsigned)

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

  # --------------------------------------------------------------------------
  # Sprint 5 — substrate extrinsic + event visibility endpoints
  # --------------------------------------------------------------------------

  @doc """
  Extrinsics in a block + the block's author (S5-T5).

  Returns `{items: [...], author: {...} | nil}`. The author block comes
  from `roko.block_authors`; it'll be `null` for blocks the sidecar
  hasn't indexed yet, or for blocks the BABE digest decode skipped.
  """
  @spec block_extrinsics(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def block_extrinsics(conn, %{"n" => n_str}) do
    case Integer.parse(n_str) do
      {n, _} when n >= 0 ->
        items =
          RokoExtrinsic.by_block_query(n)
          |> Repo.all()
          |> Enum.map(&serialize_extrinsic/1)

        author =
          case Repo.one(RokoBlockAuthor.by_block_query(n)) do
            nil -> nil
            row -> serialize_block_author(row)
          end

        json(conn, %{items: items, author: author})

      _ ->
        conn |> put_status(400) |> json(%{error: "invalid block number"})
    end
  end

  @doc "Events in a block (S5-T5)."
  @spec block_events(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def block_events(conn, %{"n" => n_str}) do
    case Integer.parse(n_str) do
      {n, _} when n >= 0 ->
        items =
          RokoEvent.by_block_query(n)
          |> Repo.all()
          |> Enum.map(&serialize_event/1)

        json(conn, %{items: items})

      _ ->
        conn |> put_status(400) |> json(%{error: "invalid block number"})
    end
  end

  @doc "Signed-only extrinsics for an address (S5-T6)."
  @spec account_extrinsics(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def account_extrinsics(conn, params) do
    limit = parse_limit(params["limit"], 100, 500)
    raw = params["address_param"]

    case decode_stash(raw) do
      {:ok, bytes} ->
        items =
          RokoExtrinsic.by_signer_query(bytes, limit)
          |> Repo.all()
          |> Enum.map(&serialize_extrinsic/1)

        json(conn, %{items: items})

      :error ->
        conn |> put_status(400) |> json(%{error: "invalid account hex"})
    end
  end

  @doc """
  Single extrinsic by hash (S5-T7). Accepts either the encoded-extrinsic
  hash or the call hash — both are matched. Includes the events emitted
  by this extrinsic from `roko.events` for the extrinsic-detail page.
  """
  @spec extrinsic_by_hash(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def extrinsic_by_hash(conn, %{"hash" => hash_hex}) do
    case decode_hash(hash_hex) do
      {:ok, bytes} ->
        case Repo.one(RokoExtrinsic.by_hash_query(bytes)) do
          nil ->
            conn |> put_status(404) |> json(%{error: "extrinsic not found"})

          ext ->
            events =
              RokoEvent.by_extrinsic_query(ext.block_number, ext.index_in_block)
              |> Repo.all()
              |> Enum.map(&serialize_event/1)

            payload = serialize_extrinsic(ext) |> Map.put(:events, events)
            json(conn, payload)
        end

      :error ->
        conn |> put_status(400) |> json(%{error: "invalid hash hex"})
    end
  end

  @doc """
  Recent extrinsics feed, optionally filtered by extrinsic class,
  pallet/method, with Blockscout-style cursor pagination via
  `(block_number, index_in_block)`.

  Pass `next_page_params` from the previous response back as
  `?block_number=…&index_in_block=…` to get the next page.
  """
  @spec extrinsics_recent(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def extrinsics_recent(conn, params) do
    case parse_extrinsic_class(params["extrinsic_class"]) do
      {:ok, extrinsic_class} ->
        limit = parse_limit(params["limit"], 50, 500)
        before_block = parse_optional_int(params["block_number"])
        before_index = parse_optional_int(params["index_in_block"])

        opts =
          []
          |> maybe_put(:extrinsic_class, extrinsic_class)
          |> maybe_put(:pallet, params["pallet"])
          |> maybe_put(:method, params["method"])
          |> maybe_put(:before_block, before_block)
          |> maybe_put(:before_index, before_index)
          |> Keyword.put(:limit, limit)

        items =
          RokoExtrinsic.recent_query(opts)
          |> Repo.all()
          |> Enum.map(&serialize_extrinsic/1)

        next_page_params =
          if length(items) >= limit do
            last = List.last(items)
            %{block_number: last.block_number, index_in_block: last.index_in_block}
          else
            nil
          end

        json(conn, %{items: items, next_page_params: next_page_params})

      :error ->
        conn
        |> put_status(400)
        |> json(%{error: "invalid extrinsic_class; expected Signed, Inherent, or Unsigned"})
    end
  end

  @doc """
  Per-block extrinsic counts for a comma-separated list of block numbers.

  Used by the EVM-side blocks list to enrich each row with a substrate count
  column without modifying Blockscout's standard `/api/v2/blocks` response
  shape. Capped at 200 numbers per call. Missing blocks are returned as 0
  so the client gets a complete map.
  """
  @spec block_counts(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def block_counts(conn, %{"numbers" => raw}) when is_binary(raw) do
    numbers =
      raw
      |> String.split(",", trim: true)
      |> Enum.flat_map(fn s ->
        case Integer.parse(s) do
          {n, _} when n >= 0 -> [n]
          _ -> []
        end
      end)
      |> Enum.uniq()
      |> Enum.take(200)

    counts =
      RokoExtrinsic.counts_by_blocks_query(numbers)
      |> Repo.all()
      |> Enum.into(%{}, fn {block_number, count} -> {block_number, count} end)

    full_counts =
      Enum.into(numbers, %{}, fn n -> {n, Map.get(counts, n, 0)} end)

    json(conn, %{counts: full_counts})
  end

  def block_counts(conn, _params) do
    conn |> put_status(400) |> json(%{error: "?numbers=N1,N2,... required"})
  end

  @doc """
  Substrate-side stats summary (S5-T8). Parallel to Blockscout's EVM-shaped
  `/api/v2/stats` (which reports `total_transactions: 0` since the chain is
  used substrate-side, not EVM-side).
  """
  @spec stats(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def stats(conn, _params) do
    # Latest known block number (max of indexed extrinsics — equivalent to
    # the sidecar cursor for our purposes).
    latest_block =
      Repo.one(from(e in RokoExtrinsic, select: max(e.block_number))) || 0

    # 24h window assuming testnet 2s blocks: 43200 blocks/day.
    # For mainnet (3s blocks) this overshoots slightly — close enough for
    # a stats summary; precise per-time-window queries can use recorded_at.
    window_start = max(latest_block - 43_200, 0)

    total_extrinsics =
      Repo.one(from(e in RokoExtrinsic, select: count(e.id))) || 0

    total_signed_extrinsics =
      Repo.one(RokoExtrinsic.count_by_class_query("Signed")) || 0

    total_native_signed_extrinsics =
      Repo.one(RokoExtrinsic.count_native_signed_query()) || 0

    signed_24h =
      Repo.one(
        from(e in RokoExtrinsic,
          where: e.block_number >= ^window_start and e.extrinsic_class == "Signed",
          select: count(e.id)
        )
      ) || 0

    inherent_24h =
      Repo.one(
        from(e in RokoExtrinsic,
          where: e.block_number >= ^window_start and e.extrinsic_class == "Inherent",
          select: count(e.id)
        )
      ) || 0

    unsigned_24h =
      Repo.one(
        from(e in RokoExtrinsic,
          where: e.block_number >= ^window_start and e.extrinsic_class == "Unsigned",
          select: count(e.id)
        )
      ) || 0

    total_events_24h =
      Repo.one(
        from(e in RokoEvent,
          where: e.block_number >= ^window_start,
          select: count(e.id)
        )
      ) || 0

    blocks_24h = max(latest_block - window_start, 1)

    avg_ext_per_block =
      Float.round((signed_24h + inherent_24h + unsigned_24h) / blocks_24h, 2)

    top_pallets =
      Repo.all(
        from(e in RokoExtrinsic,
          where: e.block_number >= ^window_start,
          group_by: [e.pallet, e.method],
          select: %{pallet: e.pallet, method: e.method, count: count(e.id)},
          order_by: [desc: count(e.id)],
          limit: 10
        )
      )

    block_authors =
      RokoBlockAuthor.authored_counts_query(window_start)
      |> Repo.all()
      |> Enum.map(fn {stash, count} -> %{author_stash: hex(stash), blocks: count} end)

    json(conn, %{
      latest_block: latest_block,
      total_extrinsics: total_extrinsics,
      total_signed_extrinsics: total_signed_extrinsics,
      total_native_signed_extrinsics: total_native_signed_extrinsics,
      signed_extrinsics_24h: signed_24h,
      inherent_extrinsics_24h: inherent_24h,
      unsigned_extrinsics_24h: unsigned_24h,
      total_events_24h: total_events_24h,
      avg_extrinsics_per_block: avg_ext_per_block,
      top_pallets_24h: top_pallets,
      block_authors_24h: block_authors
    })
  end

  @doc """
  Extension to the global search bar (S5-T9): given a 32-byte hex value,
  see if it matches a substrate block hash or an extrinsic/call hash and
  return the canonical link for the frontend to redirect to. Returns 404
  when no substrate-side match exists; frontend then falls back to
  Blockscout's existing EVM lookup.
  """
  @spec search_substrate_hash(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def search_substrate_hash(conn, %{"hash" => hash_hex}) do
    case decode_hash(hash_hex) do
      {:ok, bytes} when byte_size(bytes) == 32 ->
        cond do
          author = Repo.one(RokoBlockAuthor.by_substrate_hash_query(bytes)) ->
            json(conn, %{kind: "block", block_number: author.block_number})

          ext = Repo.one(RokoExtrinsic.by_hash_query(bytes)) ->
            json(conn, %{
              kind: "extrinsic",
              block_number: ext.block_number,
              index_in_block: ext.index_in_block
            })

          true ->
            conn |> put_status(404) |> json(%{error: "no substrate match"})
        end

      _ ->
        conn |> put_status(400) |> json(%{error: "expected 32-byte hex hash"})
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

  defp serialize_extrinsic(e) do
    %{
      id: e.id,
      block_number: e.block_number,
      block_hash: hex(e.block_hash),
      index_in_block: e.index_in_block,
      pallet: e.pallet,
      method: e.method,
      args: e.args,
      args_truncated: e.args_truncated,
      signer: hex(e.signer),
      signature: hex(e.signature),
      tip: decimal_to_string(e.tip),
      era: e.era,
      nonce: e.nonce,
      fee_paid: decimal_to_string(e.fee_paid),
      success: e.success,
      error: e.error,
      hash: hex(e.hash),
      call_hash: hex(e.call_hash),
      extrinsic_class: e.extrinsic_class,
      block_timestamp: e.block_timestamp
    }
  end

  defp serialize_event(ev) do
    %{
      id: ev.id,
      block_number: ev.block_number,
      block_hash: hex(ev.block_hash),
      extrinsic_index: ev.extrinsic_index,
      phase: ev.phase,
      index_in_block: ev.index_in_block,
      pallet: ev.pallet,
      method: ev.method,
      data: ev.data
    }
  end

  defp serialize_block_author(b) do
    %{
      block_number: b.block_number,
      block_hash: hex(b.block_hash),
      author_index: b.author_index,
      author_stash: hex(b.author_stash),
      slot: b.slot
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

  # Sprint 5: accepts 32-byte hex (block hash / extrinsic hash / call hash).
  # No length variants — substrate hashes are always 32 bytes.
  defp decode_hash("0x" <> hex_str), do: decode_hash(hex_str)

  defp decode_hash(hex_str) when is_binary(hex_str) do
    case Base.decode16(hex_str, case: :mixed) do
      {:ok, bytes} when byte_size(bytes) == 32 -> {:ok, bytes}
      _ -> :error
    end
  end

  defp decode_hash(_), do: :error

  # Conditional Keyword.put — used by /extrinsics/recent to skip nil filter args.
  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, _key, ""), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)

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

  @doc """
  Sprint 5 — same-origin JSON-RPC proxy for the Developer Console.

  The Developer Console's @polkadot/api browser-side stack would otherwise
  hit the chain's HTTPS RPC cross-origin, which (a) needs CORS preflight on
  every request and (b) sometimes wedges in the browser for reasons that
  don't reproduce server-side. Routing through this same-origin endpoint
  avoids both: the browser makes one POST to its own host, the backend
  forwards verbatim to the substrate node.

  Accepts a standard JSON-RPC envelope in the request body and returns the
  upstream substrate response verbatim. The frontend points its
  HttpProvider at `/api/v2/substrate/rpc`.
  """
  @spec rpc_proxy(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def rpc_proxy(conn, params) do
    # The :api_v2_no_session pipeline runs Plug.Parsers before this action,
    # so the raw body has already been consumed and parsed into conn.body_params.
    # Re-serialize from the parsed map (matches what the JSON-RPC client sent).
    body =
      case conn.body_params do
        # JSON-RPC batch requests are a top-level array; Plug.Parsers
        # wraps that under the "_json" key.
        %{"_json" => batch} when is_list(batch) -> Jason.encode!(batch)
        %Plug.Conn.Unfetched{} -> Jason.encode!(params)
        %{} = parsed when map_size(parsed) > 0 -> Jason.encode!(parsed)
        _ -> Jason.encode!(params)
      end

    url = rpc_url()
    headers = [{"Content-Type", "application/json"}]

    case HTTPoison.post(url, body, headers, recv_timeout: 30_000, timeout: 30_000) do
      {:ok, %HTTPoison.Response{status_code: status, body: response_body}} ->
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("access-control-allow-origin", "*")
        |> send_resp(status, response_body)

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.warning("Substrate RPC proxy to #{url} failed: #{inspect(reason)}")

        envelope =
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => nil,
            "error" => %{
              "code" => -32000,
              "message" => "upstream unreachable: #{inspect(reason)}"
            }
          })

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(502, envelope)
    end
  end

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

  defp parse_optional_int(nil), do: nil
  defp parse_optional_int(""), do: nil

  defp parse_optional_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} when n >= 0 -> n
      _ -> nil
    end
  end

  defp parse_optional_int(n) when is_integer(n) and n >= 0, do: n
  defp parse_optional_int(_), do: nil

  defp parse_extrinsic_class(nil), do: {:ok, nil}
  defp parse_extrinsic_class(""), do: {:ok, nil}

  defp parse_extrinsic_class(value) when value in @extrinsic_classes,
    do: {:ok, value}

  defp parse_extrinsic_class(_), do: :error
end
