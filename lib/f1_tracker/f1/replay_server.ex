defmodule F1Tracker.F1.ReplayServer do
  @moduledoc """
  GenServer that replays completed F1 session data progressively.

  Fetches location data in time-windowed chunks from the OpenF1 API and
  emits position updates at a configurable playback speed, creating a
  smooth race replay experience.

  ## Architecture

  - Bulk-loads small datasets (positions, laps, intervals, stints) upfront
  - Streams location data in 1-minute chunks, pre-fetching the next chunk
  - Maintains a replay clock that advances at `speed` multiplier
  - Emits location + timing snapshots every ~500ms real-time via PubSub
  """
  use GenServer
  require Logger

  alias F1Tracker.OpenF1.Client

  @pubsub F1Tracker.PubSub
  # Real-time interval between replay ticks
  @tick_interval_ms 500
  # How many seconds of location data to fetch per chunk
  @chunk_seconds 60
  # Pre-fetch next chunk when we're within this many seconds of chunk end
  @prefetch_threshold_seconds 15

  # -- Public API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Start replaying a completed session"
  def start_replay(session_key, session_meta, drivers) do
    GenServer.cast(__MODULE__, {:start_replay, session_key, session_meta, drivers})
  end

  @doc "Pause/resume playback"
  def toggle_pause do
    GenServer.cast(__MODULE__, :toggle_pause)
  end

  @doc "Set playback speed multiplier"
  def set_speed(speed) when speed > 0 do
    GenServer.cast(__MODULE__, {:set_speed, speed})
  end

  @doc "Seek to a specific progress ratio (0.0 to 1.0)"
  def seek(ratio) when ratio >= 0.0 and ratio <= 1.0 do
    GenServer.cast(__MODULE__, {:seek, ratio})
  end

  @doc "Stop replay"
  def stop_replay do
    GenServer.cast(__MODULE__, :stop_replay)
  end

  @doc "Get current replay state"
  def get_state do
    case GenServer.whereis(__MODULE__) do
      nil ->
        %{}

      pid ->
        try do
          GenServer.call(pid, :get_state, 2_000)
        catch
          :exit, _ -> %{}
        end
    end
  end

  # -- Callbacks --

  @impl true
  def init(_opts) do
    {:ok, initial_state()}
  end

  @impl true
  def handle_cast({:start_replay, session_key, session_meta, drivers}, _state) do
    Logger.info("ReplayServer starting replay for session #{session_key}")

    state = %{
      initial_state()
      | session_key: session_key,
        session_meta: session_meta,
        drivers: drivers,
        active: true,
        loading: true
    }

    send(self(), :load_session_data)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:toggle_pause, %{active: true} = state) do
    new_paused = !state.paused

    new_state =
      if new_paused do
        # Pausing — cancel tick timer
        if state.tick_ref, do: Process.cancel_timer(state.tick_ref)
        %{state | paused: true, tick_ref: nil}
      else
        # Resuming — restart tick and update wall_start to account for pause
        %{state | paused: false, wall_start: System.monotonic_time(:millisecond)}
        |> schedule_tick()
      end

    broadcast_replay_state(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:toggle_pause, state), do: {:noreply, state}

  @impl true
  def handle_cast({:set_speed, speed}, %{active: true} = state) do
    new_state = %{state | speed: speed}
    broadcast_replay_state(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:set_speed, _speed}, state), do: {:noreply, state}

  @impl true
  def handle_cast({:seek, ratio}, %{active: true} = state) do
    target_ts = interpolate_timestamp(state.session_start, state.session_end, ratio)

    # Cancel current tick
    if state.tick_ref, do: Process.cancel_timer(state.tick_ref)

    new_state = %{
      state
      | replay_cursor: target_ts,
        wall_start: System.monotonic_time(:millisecond),
        tick_ref: nil,
        current_chunk: [],
        next_chunk: nil,
        chunk_start: nil,
        chunk_end: nil
    }

    # Fetch fresh chunk at seek position and resume
    send(self(), {:fetch_chunk, target_ts})

    # Sync race control feed with seek target
    broadcast("race_control:update", race_control_up_to_cursor(state.race_control, target_ts))

    broadcast_replay_state(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:seek, _ratio}, state), do: {:noreply, state}

  @impl true
  def handle_cast(:stop_replay, state) do
    if state.tick_ref, do: Process.cancel_timer(state.tick_ref)
    {:noreply, initial_state()}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    reply = %{
      active: state.active,
      paused: state.paused,
      speed: state.speed,
      loading: state.loading,
      progress: compute_progress(state),
      replay_cursor: state.replay_cursor && DateTime.to_iso8601(state.replay_cursor),
      session_start: state.session_start && DateTime.to_iso8601(state.session_start),
      session_end: state.session_end && DateTime.to_iso8601(state.session_end),
      track_outline: state.track_outline
    }

    {:reply, reply, state}
  end

  # -- Data Loading --

  @impl true
  def handle_info(:load_session_data, %{session_key: sk} = state) do
    Logger.info("ReplayServer loading bulk session data for #{sk}")
    params = %{session_key: sk}

    # Parse session time bounds
    session_start = parse_dt!(state.session_meta.date_start)
    session_end = parse_dt!(state.session_meta.date_end)

    # Bulk-load small datasets with brief pauses to avoid API rate limits
    positions = fetch_all_positions(params)
    Process.sleep(200)
    laps = fetch_all_laps(params)
    Process.sleep(200)
    intervals = fetch_all_intervals(params)
    Process.sleep(200)
    stints = fetch_all_stints(params)
    weather = fetch_latest_weather(params)
    Process.sleep(200)
    race_control = fetch_race_control(params)
    team_radio = fetch_team_radio(params)

    {best_sectors, personal_best_sectors} =
      if laps != %{},
        do: compute_best_sectors(laps),
        else: {%{s1: nil, s2: nil, s3: nil}, %{}}

    new_state = %{
      state
      | session_start: session_start,
        session_end: session_end,
        replay_cursor: session_start,
        wall_start: System.monotonic_time(:millisecond),
        loading: false,
        # Bulk data
        all_positions: positions,
        all_laps: laps,
        all_intervals: intervals,
        stints: stints,
        weather: weather,
        race_control: race_control,
        team_radio: team_radio,
        best_sectors: best_sectors,
        personal_best_sectors: personal_best_sectors
    }

    # Fetch track outline from a single driver's lap trajectory
    Process.sleep(500)
    track_outline = fetch_track_outline(sk, session_start, state.drivers)
    Logger.info("ReplayServer track outline: #{length(track_outline)} points")

    # Broadcast static data
    broadcast("stints:update", stints)
    if weather, do: broadcast("weather:update", weather)
    broadcast("race_control:update", [])
    broadcast("team_radio:update", team_radio)
    broadcast("sectors:update", %{best: best_sectors, personal: personal_best_sectors})

    new_state =
      if track_outline != [] do
        broadcast("track_outline:update", track_outline)
        %{new_state | has_track_outline: true, track_outline: track_outline}
      else
        new_state
      end

    # Broadcast initial replay state
    broadcast_replay_state(new_state)

    # Fetch first location chunk and start playback
    send(self(), {:fetch_chunk, session_start})

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:fetch_chunk, from_dt}, %{session_key: sk} = state) do
    chunk_end = DateTime.add(from_dt, @chunk_seconds, :second)

    Logger.debug(
      "ReplayServer fetching location chunk #{DateTime.to_iso8601(from_dt)} -> #{DateTime.to_iso8601(chunk_end)}"
    )

    records = fetch_location_chunk(sk, from_dt, chunk_end)

    # Build track outline from first chunk if we don't have one yet
    chunk_outline =
      if not state.has_track_outline and records != [] do
        outline = build_outline_from_chunk(records)

        if outline != [] do
          Logger.info("ReplayServer built track outline from chunk: #{length(outline)} points")
          broadcast("track_outline:update", outline)
          outline
        else
          []
        end
      else
        []
      end

    new_state = %{
      state
      | current_chunk: state.current_chunk ++ records,
        chunk_start: state.chunk_start || from_dt,
        chunk_end: chunk_end,
        next_chunk: nil,
        has_track_outline: state.has_track_outline or chunk_outline != [],
        track_outline: if(chunk_outline != [], do: chunk_outline, else: state.track_outline)
    }

    # Start ticking if not paused
    new_state =
      if not new_state.paused do
        new_state
        |> Map.put(:wall_start, System.monotonic_time(:millisecond))
        |> schedule_tick()
      else
        new_state
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:prefetched_chunk, chunk_data, chunk_start, chunk_end}, state) do
    {:noreply, %{state | next_chunk: {chunk_data, chunk_start, chunk_end}}}
  end

  # -- Replay Tick --

  @impl true
  def handle_info(:replay_tick, %{active: true, paused: false} = state) do
    now_wall = System.monotonic_time(:millisecond)
    elapsed_wall_ms = now_wall - state.wall_start
    elapsed_session_ms = trunc(elapsed_wall_ms * state.speed)
    new_cursor = DateTime.add(state.replay_cursor, elapsed_session_ms, :millisecond)

    # Check if replay is done
    if DateTime.compare(new_cursor, state.session_end) != :lt do
      Logger.info("ReplayServer: replay complete")
      broadcast("replay:finished", %{})
      broadcast_replay_state(%{state | replay_cursor: state.session_end, paused: true})
      {:noreply, %{state | replay_cursor: state.session_end, paused: true, tick_ref: nil}}
    else
      # Update wall_start for next tick calculation
      new_state = %{state | replay_cursor: new_cursor, wall_start: now_wall}

      # Emit current snapshot
      emit_snapshot(new_state, state.replay_cursor, new_cursor)

      # Check if we need to advance to next chunk
      new_state = maybe_advance_chunk(new_state, new_cursor)

      # Schedule next tick
      new_state = schedule_tick(new_state)

      {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(:replay_tick, state) do
    # Not active or paused, ignore
    {:noreply, state}
  end

  @impl true
  def handle_info(_, state), do: {:noreply, state}

  # -- Private: Snapshot Emission --

  defp emit_snapshot(state, prev_cursor, cursor) do
    cursor_str = DateTime.to_iso8601(cursor)

    # Find locations at cursor time from current chunk
    locations = locations_at(state.current_chunk, cursor_str, state.drivers)

    # Find positions at cursor time — latest position per driver up to cursor
    positions = positions_at(state.all_positions, cursor_str)

    # Find laps at cursor time (latest lap per driver up to cursor)
    laps = laps_at(state.all_laps, cursor_str)

    # Find intervals at cursor time — latest interval per driver up to cursor
    intervals = intervals_at(state.all_intervals, cursor_str)

    if locations != %{} do
      broadcast("locations:update", locations)
    end

    if positions != [] do
      broadcast("positions:update", positions)
    end

    if laps != %{} do
      broadcast("laps:update", laps)
    end

    if intervals != %{} do
      broadcast("intervals:update", intervals)
    end

    race_control_new = race_control_new_events(state.race_control, prev_cursor, cursor)

    if race_control_new != [] do
      broadcast("race_control:new", race_control_new)
    end

    # Broadcast replay progress
    broadcast_replay_state(state)
  end

  defp race_control_new_events(events, prev_cursor, cursor) do
    prev_str = DateTime.to_iso8601(prev_cursor)
    cursor_str = DateTime.to_iso8601(cursor)

    Enum.filter(events, fn event ->
      event_ts = event["date"] || event[:date]
      event_ts && event_ts > prev_str && event_ts <= cursor_str
    end)
  end

  defp race_control_up_to_cursor(events, cursor) do
    cursor_str = DateTime.to_iso8601(cursor)

    events
    |> Enum.filter(fn event ->
      event_ts = event["date"] || event[:date]
      event_ts && event_ts <= cursor_str
    end)
    |> Enum.take(-10)
  end

  defp locations_at(chunk, cursor_str, _drivers) do
    # Group by driver, find latest record at or before cursor
    chunk
    |> Enum.filter(fn r -> r["date"] <= cursor_str end)
    |> Enum.group_by(& &1["driver_number"])
    |> Map.new(fn {driver_num, entries} ->
      latest = Enum.max_by(entries, & &1["date"])

      {driver_num,
       %{
         x: latest["x"],
         y: latest["y"],
         z: latest["z"],
         date: latest["date"]
       }}
    end)
  end

  defp positions_at(all_positions, cursor_str) do
    # Find the latest position per driver at or before cursor
    all_positions
    |> Enum.filter(fn r -> r["date"] && r["date"] <= cursor_str end)
    |> Enum.group_by(& &1["driver_number"])
    |> Enum.map(fn {driver_num, entries} ->
      latest = Enum.max_by(entries, & &1["date"])
      %{driver_number: driver_num, position: latest["position"]}
    end)
    |> Enum.sort_by(& &1.position)
  end

  defp intervals_at(all_intervals, cursor_str) do
    # Find the latest interval per driver at or before cursor
    all_intervals
    |> Enum.filter(fn r -> r["date"] && r["date"] <= cursor_str end)
    |> Enum.group_by(& &1["driver_number"])
    |> Map.new(fn {driver_num, entries} ->
      latest = Enum.max_by(entries, & &1["date"])

      {driver_num,
       %{
         gap_to_leader: latest["gap_to_leader"],
         interval: latest["interval"],
         date: latest["date"]
       }}
    end)
  end

  defp laps_at(all_laps, cursor_str) do
    Map.new(all_laps, fn {driver_num, driver_laps} ->
      laps_up_to =
        Enum.filter(driver_laps, fn lap ->
          lap.date && lap.date <= cursor_str
        end)

      {driver_num, laps_up_to}
    end)
    |> Enum.reject(fn {_k, v} -> v == [] end)
    |> Map.new()
  end

  # -- Private: Chunk Management --

  defp maybe_advance_chunk(state, cursor) do
    cond do
      # Current chunk exhausted — swap in next chunk
      state.chunk_end && DateTime.compare(cursor, state.chunk_end) != :lt && state.next_chunk ->
        {data, start, end_dt} = state.next_chunk

        %{
          state
          | current_chunk: data,
            chunk_start: start,
            chunk_end: end_dt,
            next_chunk: nil
        }
        |> maybe_prefetch(cursor)

      # Close to end of current chunk — prefetch next
      true ->
        maybe_prefetch(state, cursor)
    end
  end

  defp maybe_prefetch(state, cursor) do
    if state.chunk_end && state.next_chunk == nil do
      seconds_to_end = DateTime.diff(state.chunk_end, cursor, :second)

      if seconds_to_end <= @prefetch_threshold_seconds do
        prefetch_next_chunk(state)
      else
        state
      end
    else
      state
    end
  end

  defp prefetch_next_chunk(%{chunk_end: chunk_end, session_key: sk} = state) do
    next_start = chunk_end
    next_end = DateTime.add(chunk_end, @chunk_seconds, :second)

    # Fetch async in a Task to not block the GenServer
    parent = self()

    Task.start(fn ->
      data = fetch_location_chunk(sk, next_start, next_end)
      send(parent, {:prefetched_chunk, data, next_start, next_end})
    end)

    state
  end

  defp fetch_location_chunk(session_key, from_dt, to_dt) do
    from_str = DateTime.to_iso8601(from_dt)
    to_str = DateTime.to_iso8601(to_dt)

    case Client.get_location_range(session_key, from_str, to_str) do
      {:ok, data} when is_list(data) -> data
      _ -> []
    end
  end

  @doc false
  defp fetch_track_outline(session_key, session_start, drivers) do
    # Try a few drivers individually in a bounded window.
    # This avoids loading huge all-driver datasets into memory.
    if map_size(drivers) == 0 do
      []
    else
      outline_start = DateTime.add(session_start, 120, :second)
      outline_end = DateTime.add(outline_start, 420, :second)

      from_str = DateTime.to_iso8601(outline_start)
      to_str = DateTime.to_iso8601(outline_end)

      outline = build_outline_from_driver_candidates(session_key, drivers, from_str, to_str)

      if outline == [] do
        Logger.warning("ReplayServer: track outline fetch returned no data")
      else
        Logger.info("ReplayServer fetched track outline: #{length(outline)} points")
      end

      outline
    end
  end

  defp build_outline_from_driver_candidates(session_key, drivers, from_str, to_str) do
    drivers
    |> Map.keys()
    |> Enum.sort()
    |> Enum.take(6)
    |> Enum.reduce_while([], fn driver_num, _acc ->
      case Client.get_location_for_driver(session_key, driver_num, from_str, to_str) do
        {:ok, data} when is_list(data) and length(data) > 100 ->
          outline = build_clean_outline(data)

          if valid_outline?(outline) do
            {:halt, outline}
          else
            {:cont, []}
          end

        _ ->
          {:cont, []}
      end
    end)
  end

  defp build_outline_from_chunk(records) do
    # Extract one driver's path from the chunk to trace the circuit.
    # Pick the driver with the most data points (most likely on track).
    records
    |> Enum.group_by(& &1["driver_number"])
    |> Enum.max_by(fn {_driver, entries} -> length(entries) end, fn -> {nil, []} end)
    |> case do
      {nil, _} -> []
      {_driver, entries} -> build_clean_outline(entries)
    end
  end

  defp build_clean_outline(data) do
    data
    |> Enum.sort_by(& &1["date"])
    |> Enum.reduce([], fn record, acc ->
      x = record["x"]
      y = record["y"]

      case acc do
        [] ->
          [%{x: x, y: y}]

        [prev | _] ->
          dx = x - prev.x
          dy = y - prev.y
          dist = :math.sqrt(dx * dx + dy * dy)

          # Skip if too close (clustering) or too far (pit teleport)
          cond do
            dist < 20 -> acc
            dist > 5000 -> acc
            true -> [%{x: x, y: y} | acc]
          end
      end
    end)
    |> Enum.reverse()
  end

  defp valid_outline?(outline) do
    if length(outline) < 120 do
      false
    else
      first = hd(outline)
      last = List.last(outline)
      dx = first.x - last.x
      dy = first.y - last.y
      closure_dist = :math.sqrt(dx * dx + dy * dy)

      closure_dist < 1_200
    end
  end

  # -- Private: Data Fetching --

  defp fetch_all_positions(params) do
    case Client.get_position(params) do
      {:ok, data} when is_list(data) -> data
      _ -> []
    end
  end

  defp fetch_all_laps(params) do
    case Client.get_laps(params) do
      {:ok, data} when is_list(data) ->
        Enum.reduce(data, %{}, fn lap, acc ->
          driver_num = lap["driver_number"]
          driver_laps = Map.get(acc, driver_num, [])

          new_lap = %{
            lap_number: lap["lap_number"],
            lap_duration: lap["lap_duration"],
            sector_1: lap["duration_sector_1"],
            sector_2: lap["duration_sector_2"],
            sector_3: lap["duration_sector_3"],
            is_pit_out: lap["is_pit_out_lap"],
            date: lap["date_start"]
          }

          Map.put(acc, driver_num, driver_laps ++ [new_lap])
        end)

      _ ->
        %{}
    end
  end

  defp fetch_all_intervals(params) do
    case Client.get_intervals(params) do
      {:ok, data} when is_list(data) -> data
      _ -> []
    end
  end

  defp fetch_all_stints(params) do
    case Client.get_stints(params) do
      {:ok, data} when is_list(data) and data != [] ->
        data
        |> Enum.group_by(& &1["driver_number"])
        |> Map.new(fn {driver_num, entries} ->
          latest = Enum.max_by(entries, & &1["stint_number"])

          {driver_num,
           %{
             compound: latest["compound"],
             tyre_age: latest["tyre_age_at_start"],
             stint_number: latest["stint_number"],
             lap_start: latest["lap_start"],
             lap_end: latest["lap_end"]
           }}
        end)

      _ ->
        %{}
    end
  end

  defp fetch_latest_weather(params) do
    case Client.get_weather(params) do
      {:ok, [latest | _]} -> latest
      _ -> nil
    end
  end

  defp fetch_race_control(params) do
    case Client.get_race_control(params) do
      {:ok, data} when is_list(data) -> data
      _ -> []
    end
  end

  defp fetch_team_radio(params) do
    case Client.get_team_radio(params) do
      {:ok, data} when is_list(data) and data != [] ->
        data
        |> Enum.map(fn r ->
          %{
            driver_number: r["driver_number"],
            recording_url: r["recording_url"],
            date: r["date"]
          }
        end)
        |> Enum.uniq_by(& &1.recording_url)
        |> Enum.take(-20)

      _ ->
        []
    end
  end

  # -- Private: Sector Computation (duplicated from SessionServer for isolation) --

  defp compute_best_sectors(laps) do
    all_laps = laps |> Map.values() |> List.flatten()

    best_sectors = %{
      s1: all_laps |> Enum.map(& &1.sector_1) |> Enum.filter(& &1) |> Enum.min(fn -> nil end),
      s2: all_laps |> Enum.map(& &1.sector_2) |> Enum.filter(& &1) |> Enum.min(fn -> nil end),
      s3: all_laps |> Enum.map(& &1.sector_3) |> Enum.filter(& &1) |> Enum.min(fn -> nil end)
    }

    personal_best_sectors =
      Map.new(laps, fn {driver_num, driver_laps} ->
        {driver_num,
         %{
           s1:
             driver_laps
             |> Enum.map(& &1.sector_1)
             |> Enum.filter(& &1)
             |> Enum.min(fn -> nil end),
           s2:
             driver_laps
             |> Enum.map(& &1.sector_2)
             |> Enum.filter(& &1)
             |> Enum.min(fn -> nil end),
           s3:
             driver_laps
             |> Enum.map(& &1.sector_3)
             |> Enum.filter(& &1)
             |> Enum.min(fn -> nil end)
         }}
      end)

    {best_sectors, personal_best_sectors}
  end

  # -- Private: Helpers --

  defp initial_state do
    %{
      session_key: nil,
      session_meta: nil,
      drivers: %{},
      active: false,
      paused: false,
      loading: false,
      speed: 1,
      replay_cursor: nil,
      wall_start: nil,
      session_start: nil,
      session_end: nil,
      # Location chunk state
      current_chunk: [],
      next_chunk: nil,
      chunk_start: nil,
      chunk_end: nil,
      tick_ref: nil,
      has_track_outline: false,
      track_outline: [],
      # Bulk data
      all_positions: [],
      all_laps: %{},
      all_intervals: [],
      stints: %{},
      weather: nil,
      race_control: [],
      team_radio: [],
      best_sectors: %{s1: nil, s2: nil, s3: nil},
      personal_best_sectors: %{}
    }
  end

  defp schedule_tick(state) do
    ref = Process.send_after(self(), :replay_tick, @tick_interval_ms)
    %{state | tick_ref: ref}
  end

  defp compute_progress(%{session_start: nil}), do: 0.0
  defp compute_progress(%{session_end: nil}), do: 0.0
  defp compute_progress(%{replay_cursor: nil}), do: 0.0

  defp compute_progress(state) do
    total = DateTime.diff(state.session_end, state.session_start, :second)
    elapsed = DateTime.diff(state.replay_cursor, state.session_start, :second)
    if total > 0, do: min(elapsed / total, 1.0), else: 0.0
  end

  defp interpolate_timestamp(start_dt, end_dt, ratio) do
    total_seconds = DateTime.diff(end_dt, start_dt, :second)
    offset = trunc(total_seconds * ratio)
    DateTime.add(start_dt, offset, :second)
  end

  defp parse_dt!(date_str) do
    case DateTime.from_iso8601(date_str) do
      {:ok, dt, _} -> dt
      _ -> raise "Invalid datetime: #{date_str}"
    end
  end

  defp broadcast(event, data) do
    Phoenix.PubSub.broadcast(@pubsub, "f1:live", {event, data})
  end

  defp broadcast_replay_state(state) do
    broadcast("replay:state", %{
      active: state.active,
      paused: state.paused,
      speed: state.speed,
      loading: state.loading,
      progress: compute_progress(state),
      replay_cursor: state.replay_cursor && DateTime.to_iso8601(state.replay_cursor)
    })
  end
end
