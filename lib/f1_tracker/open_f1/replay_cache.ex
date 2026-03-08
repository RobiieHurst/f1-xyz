defmodule F1Tracker.OpenF1.ReplayCache do
  @moduledoc """
  DuckDB + Parquet-backed cache for replay chunk payloads.

  Stores chunk responses keyed by endpoint/session/time-window in DuckDB and
  continuously exports per-session parquet snapshots for fast local analytics.
  """

  use GenServer
  require Logger

  @table "replay_chunk_cache"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get(endpoint, session_key, from_iso, to_iso)
      when is_binary(endpoint) and is_integer(session_key) do
    GenServer.call(__MODULE__, {:get, endpoint, session_key, from_iso, to_iso}, 15_000)
  catch
    :exit, _ -> :miss
  end

  def put(endpoint, session_key, from_iso, to_iso, payload)
      when is_binary(endpoint) and is_integer(session_key) and is_list(payload) do
    GenServer.cast(__MODULE__, {:put, endpoint, session_key, from_iso, to_iso, payload})
  end

  def put(_endpoint, _session_key, _from_iso, _to_iso, _payload), do: :ok

  def available? do
    GenServer.call(__MODULE__, :available?)
  catch
    :exit, _ -> false
  end

  @impl true
  def init(_opts) do
    duckdb = System.find_executable("duckdb")

    base_dir =
      Application.get_env(:f1_tracker, :openf1_replay_cache_dir) ||
        Path.join(System.tmp_dir!(), "f1_tracker_replay_cache")

    db_path =
      Application.get_env(:f1_tracker, :openf1_replay_cache_db) ||
        Path.join(base_dir, "replay_cache.duckdb")

    parquet_dir = Path.join(base_dir, "parquet")
    tmp_dir = Path.join(base_dir, "tmp")

    File.mkdir_p!(parquet_dir)
    File.mkdir_p!(tmp_dir)

    state = %{
      enabled: is_binary(duckdb),
      duckdb: duckdb,
      db_path: db_path,
      parquet_dir: parquet_dir,
      tmp_dir: tmp_dir
    }

    if state.enabled do
      case ensure_schema(state) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("ReplayCache schema init failed: #{inspect(reason)}")
      end
    else
      Logger.warning("ReplayCache disabled: duckdb binary not found")
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:available?, _from, state), do: {:reply, state.enabled, state}

  @impl true
  def handle_call(
        {:get, endpoint, session_key, from_iso, to_iso},
        _from,
        %{enabled: false} = state
      ) do
    _ = {endpoint, session_key, from_iso, to_iso}
    {:reply, :miss, state}
  end

  @impl true
  def handle_call({:get, endpoint, session_key, from_iso, to_iso}, _from, state) do
    from_key = normalize_iso_key(from_iso)
    to_key = normalize_iso_key(to_iso)
    reply = fetch_chunk(state, endpoint, session_key, from_key, to_key)

    case reply do
      {:ok, payload} ->
        Logger.info(
          "ReplayCache HIT endpoint=#{endpoint} session=#{session_key} range=#{from_iso}..#{to_iso} rows=#{length(payload)}"
        )

      :miss ->
        Logger.info(
          "ReplayCache MISS endpoint=#{endpoint} session=#{session_key} range=#{from_iso}..#{to_iso}"
        )
    end

    {:reply, reply, state}
  end

  @impl true
  def handle_cast(
        {:put, _endpoint, _session_key, _from_iso, _to_iso, payload},
        %{enabled: false} = state
      ) do
    _ = payload
    {:noreply, state}
  end

  @impl true
  def handle_cast({:put, endpoint, session_key, from_iso, to_iso, payload}, state) do
    from_key = normalize_iso_key(from_iso)
    to_key = normalize_iso_key(to_iso)
    result = store_chunk(state, endpoint, session_key, from_key, to_key, payload)

    case result do
      {:ok, rows} ->
        Logger.info(
          "ReplayCache STORE endpoint=#{endpoint} session=#{session_key} range=#{from_iso}..#{to_iso} rows=#{rows}"
        )

      {:error, reason} ->
        Logger.warning(
          "ReplayCache STORE_FAILED endpoint=#{endpoint} session=#{session_key} range=#{from_iso}..#{to_iso} reason=#{inspect(reason)}"
        )
    end

    {:noreply, state}
  end

  defp fetch_chunk(state, endpoint, session_key, from_iso, to_iso) do
    sql =
      "SELECT payload_json FROM #{@table} WHERE endpoint = '#{esc(endpoint)}' AND session_key = #{session_key} AND from_iso = '#{esc(from_iso)}' AND to_iso = '#{esc(to_iso)}' LIMIT 1;"

    with :ok <- ensure_schema(state),
         {:ok, rows} <- run_query_json(state, sql),
         [%{"payload_json" => payload_json} | _] <- rows,
         {:ok, payload} <- Jason.decode(payload_json) do
      {:ok, payload}
    else
      _ -> :miss
    end
  end

  defp store_chunk(state, endpoint, session_key, from_iso, to_iso, payload) do
    row_path = Path.join(state.tmp_dir, "put_#{System.unique_integer([:positive])}.json")
    inserted_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    row = [
      %{
        endpoint: endpoint,
        session_key: session_key,
        from_iso: from_iso,
        to_iso: to_iso,
        payload_json: Jason.encode!(payload),
        inserted_at: inserted_at
      }
    ]

    with {:ok, body} <- Jason.encode(row),
         :ok <- File.write(row_path, body),
         :ok <- ensure_schema(state),
         {:ok, _} <- run_sql(state, upsert_sql(row_path, endpoint, session_key, from_iso, to_iso)),
         {:ok, _} <- run_sql(state, export_parquet_sql(state.parquet_dir, endpoint, session_key)) do
      {:ok, length(payload)}
    else
      error -> {:error, error}
    end
    |> then(fn result ->
      _ = File.rm(row_path)
      result
    end)
  end

  defp ensure_schema(state) do
    sql =
      """
      CREATE TABLE IF NOT EXISTS #{@table} (
        endpoint VARCHAR,
        session_key BIGINT,
        from_iso VARCHAR,
        to_iso VARCHAR,
        payload_json VARCHAR,
        inserted_at VARCHAR,
        PRIMARY KEY(endpoint, session_key, from_iso, to_iso)
      );
      """

    case run_sql(state, sql) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp upsert_sql(row_path, endpoint, session_key, from_iso, to_iso) do
    """
    DELETE FROM #{@table}
    WHERE endpoint = '#{esc(endpoint)}'
      AND session_key = #{session_key}
      AND from_iso = '#{esc(from_iso)}'
      AND to_iso = '#{esc(to_iso)}';

    INSERT INTO #{@table}
    SELECT endpoint, session_key, from_iso, to_iso, payload_json, inserted_at
    FROM read_json_auto('#{esc(row_path)}');
    """
  end

  defp export_parquet_sql(parquet_dir, endpoint, session_key) do
    parquet_path = Path.join(parquet_dir, "#{endpoint}_session_#{session_key}.parquet")

    """
    COPY (
      SELECT *
      FROM #{@table}
      WHERE endpoint = '#{esc(endpoint)}' AND session_key = #{session_key}
      ORDER BY from_iso ASC
    ) TO '#{esc(parquet_path)}' (FORMAT PARQUET);
    """
  end

  defp run_sql(%{duckdb: nil}, _sql), do: {:error, :duckdb_missing}

  defp run_sql(state, sql) do
    case System.cmd(state.duckdb, [state.db_path, sql], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:duckdb_sql_failed, status, output}}
    end
  end

  defp run_query_json(%{duckdb: nil}, _sql), do: {:error, :duckdb_missing}

  defp run_query_json(state, sql) do
    case System.cmd(state.duckdb, ["-json", state.db_path, sql], stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, rows} when is_list(rows) -> {:ok, rows}
          other -> {:error, {:invalid_json_result, other, output}}
        end

      {output, status} ->
        {:error, {:duckdb_query_failed, status, output}}
    end
  end

  defp esc(value) when is_binary(value), do: String.replace(value, "'", "''")
  defp esc(value), do: value |> to_string() |> esc()

  defp normalize_iso_key(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      _ -> value
    end
  end

  defp normalize_iso_key(value), do: value
end
