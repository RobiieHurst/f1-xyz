defmodule F1Tracker.OpenF1.ResponseCache do
  @moduledoc """
  Lightweight persistent response cache for OpenF1 REST requests.

  Uses DETS (disk-backed Erlang table) so replay and repeated queries can be
  served locally instead of hammering OpenF1.
  """

  use GenServer

  @table :openf1_response_cache
  @cleanup_interval_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get(path, params) do
    GenServer.call(__MODULE__, {:get, cache_key(path, params)})
  catch
    :exit, _ -> :miss
  end

  def put(path, params, payload, ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0 do
    GenServer.cast(__MODULE__, {:put, cache_key(path, params), payload, ttl_ms})
  end

  def put(_path, _params, _payload, _ttl_ms), do: :ok

  @impl true
  def init(_opts) do
    path = cache_file_path()
    File.mkdir_p!(Path.dirname(path))

    case :dets.open_file(@table, type: :set, file: String.to_charlist(path)) do
      {:ok, _table} ->
        schedule_cleanup()
        {:ok, %{path: path}}

      {:error, reason} ->
        {:stop, {:cache_open_failed, reason}}
    end
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    now = System.system_time(:millisecond)

    reply =
      case :dets.lookup(@table, key) do
        [{^key, inserted_at, ttl_ms, payload}] when now - inserted_at <= ttl_ms ->
          {:ok, payload}

        [{^key, _inserted_at, _ttl_ms, _payload}] ->
          _ = :dets.delete(@table, key)
          :miss

        _ ->
          :miss
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_cast({:put, key, payload, ttl_ms}, state) do
    now = System.system_time(:millisecond)
    _ = :dets.insert(@table, {key, now, ttl_ms, payload})
    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.system_time(:millisecond)

    :dets.foldl(
      fn {key, inserted_at, ttl_ms, _payload}, _acc ->
        if now - inserted_at > ttl_ms do
          _ = :dets.delete(@table, key)
        end

        :ok
      end,
      :ok,
      @table
    )

    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    _ = :dets.close(@table)
    :ok
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, @cleanup_interval_ms)

  defp cache_file_path do
    Application.get_env(:f1_tracker, :openf1_cache_file) ||
      Path.join(System.tmp_dir!(), "f1_tracker_openf1_cache.dets")
  end

  defp cache_key(path, params) do
    normalized = normalize_params(params)
    :erlang.phash2({path, normalized}, 4_294_967_295)
  end

  defp normalize_params(params) when is_map(params) do
    params
    |> Enum.map(fn {k, v} -> {to_string(k), normalize_value(v)} end)
    |> Enum.sort()
  end

  defp normalize_params(params) when is_list(params) do
    Enum.map(params, fn
      {k, v} -> {to_string(k), normalize_value(v)}
      other -> other
    end)
  end

  defp normalize_params(_), do: []

  defp normalize_value(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp normalize_value(v), do: inspect(v)
end
