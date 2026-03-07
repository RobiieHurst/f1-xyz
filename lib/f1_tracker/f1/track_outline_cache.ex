defmodule F1Tracker.F1.TrackOutlineCache do
  @moduledoc """
  Cache for per-circuit track outlines.

  - Loads/saves `priv/data/track_outlines.json`
  - Optionally exports to DuckDB + Parquet when `duckdb` CLI is available
  """

  use GenServer
  require Logger

  @json_file "track_outlines.json"
  @duckdb_file "track_outlines.duckdb"
  @parquet_file "track_outlines.parquet"
  @rows_json_file "track_outlines_rows.json"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get(circuit_key) when is_integer(circuit_key) do
    GenServer.call(__MODULE__, {:get, circuit_key})
  end

  def get(_), do: []

  def put(circuit_key, outline) when is_integer(circuit_key) and is_list(outline) do
    GenServer.cast(__MODULE__, {:put, circuit_key, outline})
  end

  def put(_, _), do: :ok

  @impl true
  def init(_opts) do
    priv = :code.priv_dir(:f1_tracker)
    data_dir = Path.join(priv, "data")
    File.mkdir_p!(data_dir)

    json_path = Path.join(data_dir, @json_file)
    duckdb_path = Path.join(data_dir, @duckdb_file)
    parquet_path = Path.join(data_dir, @parquet_file)
    rows_json_path = Path.join(data_dir, @rows_json_file)

    outlines = load_json(json_path)

    {:ok,
     %{
       outlines: outlines,
       json_path: json_path,
       duckdb_path: duckdb_path,
       parquet_path: parquet_path,
       rows_json_path: rows_json_path
     }}
  end

  @impl true
  def handle_call({:get, circuit_key}, _from, state) do
    {:reply, Map.get(state.outlines, circuit_key, []), state}
  end

  @impl true
  def handle_cast({:put, circuit_key, outline}, state) do
    outline = normalize_outline(outline)

    new_state =
      if outline == [] do
        state
      else
        outlines = Map.put(state.outlines, circuit_key, outline)

        persist_json(state.json_path, outlines)
        maybe_export_duckdb_and_parquet(state, outlines)

        %{state | outlines: outlines}
      end

    {:noreply, new_state}
  end

  defp load_json(path) do
    case File.read(path) do
      {:ok, body} ->
        with {:ok, raw} <- Jason.decode(body),
             true <- is_map(raw) do
          Map.new(raw, fn {k, v} ->
            {String.to_integer(k), normalize_outline(v)}
          end)
        else
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp persist_json(path, outlines) do
    serializable =
      Map.new(outlines, fn {k, v} ->
        {Integer.to_string(k), v}
      end)

    case Jason.encode(serializable) do
      {:ok, body} ->
        File.write(path, body)

      {:error, reason} ->
        Logger.warning("TrackOutlineCache failed to encode JSON: #{inspect(reason)}")
    end
  end

  defp maybe_export_duckdb_and_parquet(state, outlines) do
    case System.find_executable("duckdb") do
      nil ->
        :ok

      duckdb ->
        rows =
          outlines
          |> Enum.flat_map(fn {circuit_key, points} ->
            points
            |> Enum.with_index()
            |> Enum.map(fn {point, idx} ->
              %{
                circuit_key: circuit_key,
                point_index: idx,
                x: point.x,
                y: point.y
              }
            end)
          end)

        case Jason.encode(rows) do
          {:ok, body} ->
            _ = File.write(state.rows_json_path, body)

            sql =
              """
              CREATE OR REPLACE TABLE track_outlines AS
              SELECT * FROM read_json_auto('#{state.rows_json_path}');
              COPY track_outlines TO '#{state.parquet_path}' (FORMAT PARQUET);
              """

            _ = System.cmd(duckdb, [state.duckdb_path, sql], stderr_to_stdout: true)
            :ok

          {:error, reason} ->
            Logger.warning("TrackOutlineCache failed to encode DuckDB rows: #{inspect(reason)}")
        end
    end
  end

  defp normalize_outline(outline) when is_list(outline) do
    outline
    |> Enum.map(fn
      %{"x" => x, "y" => y} -> %{x: x, y: y}
      %{x: x, y: y} -> %{x: x, y: y}
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_outline(_), do: []
end
