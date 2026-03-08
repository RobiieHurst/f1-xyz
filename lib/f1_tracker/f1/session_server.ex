defmodule F1Tracker.F1.SessionServer do
  @moduledoc """
  GenServer that polls OpenF1 for live session data and broadcasts
  updates via PubSub. Manages state for the current active session.
  """
  use GenServer
  require Logger

  alias F1Tracker.DataProvider
  alias F1Tracker.F1.TrackOutlineCache
  alias F1Tracker.OpenF1.MQTTStream

  @poll_interval_ms 6_000
  @location_poll_ms 3_000
  @car_data_poll_ms 5_000
  @pubsub F1Tracker.PubSub

  # -- Public API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Start tracking a specific session"
  def track_session(session_key) do
    GenServer.cast(__MODULE__, {:track_session, session_key})
  end

  @doc "Stop tracking"
  def stop_tracking do
    GenServer.cast(__MODULE__, :stop_tracking)
  end

  @doc "Get current state snapshot"
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  @doc "List available sessions"
  def list_sessions do
    DataProvider.get_sessions()
  end

  @doc "Start replay from a specific timestamp"
  def replay_from(session_key, from_timestamp) do
    GenServer.cast(__MODULE__, {:replay_from, session_key, from_timestamp})
  end

  @doc "Set focused driver for telemetry polling"
  def set_focus_driver(driver_number) when is_integer(driver_number) do
    GenServer.cast(__MODULE__, {:set_focus_driver, driver_number})
  end

  def set_focus_driver(nil) do
    GenServer.cast(__MODULE__, {:set_focus_driver, nil})
  end

  @doc "Merge live locations received from MQTT"
  def mqtt_locations_update(locations) when is_map(locations) do
    GenServer.cast(__MODULE__, {:mqtt_locations_update, locations})
  end

  @doc "Merge live telemetry/DRS received from MQTT"
  def mqtt_drs_update(drs_map) when is_map(drs_map) do
    GenServer.cast(__MODULE__, {:mqtt_drs_update, drs_map})
  end

  # -- Callbacks --

  @impl true
  def init(_opts) do
    state = %{
      session_key: nil,
      tracking: false,
      drivers: %{},
      positions: [],
      locations: %{},
      laps: %{},
      intervals: %{},
      race_control: [],
      pit_stops: [],
      weather: nil,
      stints: %{},
      best_sectors: %{s1: nil, s2: nil, s3: nil},
      personal_best_sectors: %{},
      drs: %{},
      team_radio: [],
      last_location_ts: nil,
      last_lap_ts: nil,
      last_interval_ts: nil,
      last_position_ts: nil,
      last_drs_ts: nil,
      last_radio_ts: nil,
      last_race_control_ts: nil,
      replay_mode: false,
      replay_from: nil,
      focus_driver: nil,
      last_car_poll_at: nil,
      mqtt_live: false,
      session_meta: nil,
      track_outline: []
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:track_session, session_key}, state) do
    Logger.info("Starting to track session: #{session_key}")
    # Kick off async driver fetch to avoid blocking
    send(self(), {:init_session, session_key})

    {:noreply, reset_session_state(state, session_key)}
  end

  @impl true
  def handle_cast(:stop_tracking, state) do
    Logger.info("Stopping session tracking")
    MQTTStream.stop_stream()
    {:noreply, %{state | tracking: false, focus_driver: nil, mqtt_live: false}}
  end

  @impl true
  def handle_cast({:set_focus_driver, driver_number}, state) do
    {:noreply, %{state | focus_driver: driver_number}}
  end

  @impl true
  def handle_cast(
        {:mqtt_locations_update, locations},
        %{tracking: true, replay_mode: false} = state
      ) do
    {:noreply, %{state | locations: Map.merge(state.locations || %{}, locations)}}
  end

  @impl true
  def handle_cast({:mqtt_locations_update, _locations}, state), do: {:noreply, state}

  @impl true
  def handle_cast({:mqtt_drs_update, drs_map}, %{tracking: true, replay_mode: false} = state) do
    {:noreply, %{state | drs: Map.merge(state.drs || %{}, drs_map)}}
  end

  @impl true
  def handle_cast({:mqtt_drs_update, _drs_map}, state), do: {:noreply, state}

  @impl true
  def handle_cast({:replay_from, session_key, from_timestamp}, state) do
    Logger.info("Starting replay from #{from_timestamp} for session #{session_key}")
    MQTTStream.stop_stream()
    # Kick off async driver fetch + historical data fetch
    send(self(), {:init_replay, session_key, from_timestamp})

    new_state = reset_session_state(state, session_key)
    {:noreply, %{new_state | replay_mode: true, replay_from: from_timestamp}}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info({:init_session, session_key}, state) do
    drivers = fetch_drivers(session_key)
    session_meta = fetch_session_meta(session_key)
    cached_outline = get_cached_outline(session_meta)

    completed? =
      case session_meta do
        %{date_end: date_end} when not is_nil(date_end) -> session_ended?(date_end)
        _ -> false
      end

    new_state = %{
      state
      | drivers: drivers,
        session_meta: session_meta,
        track_outline: cached_outline
    }

    if completed? do
      Logger.info("Completed session detected, starting replay")
      MQTTStream.stop_stream()
      # Delegate to ReplayServer for completed sessions
      F1Tracker.F1.ReplayServer.start_replay(session_key, session_meta, drivers)

      broadcast("session:started", %{
        session_key: session_key,
        drivers: drivers,
        session_meta: session_meta
      })

      if cached_outline != [] do
        broadcast("track_outline:update", cached_outline)
      end

      {:noreply, new_state}
    else
      # Live session — start incremental polling
      mqtt_live = maybe_start_mqtt_stream(session_key)
      schedule_poll(:locations)
      schedule_poll(:timing)
      schedule_poll(:race_control)

      broadcast("session:started", %{
        session_key: session_key,
        drivers: drivers,
        session_meta: session_meta
      })

      if cached_outline != [] do
        broadcast("track_outline:update", cached_outline)
      else
        # Fetch track outline in background for live sessions that have been running
        send(self(), :fetch_track_outline)
      end

      now_iso = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      {:noreply, %{new_state | last_race_control_ts: now_iso, mqtt_live: mqtt_live}}
    end
  end

  @impl true
  def handle_info({:init_replay, session_key, from_timestamp}, state) do
    MQTTStream.stop_stream()
    drivers = fetch_drivers(session_key)
    session_meta = fetch_session_meta(session_key)
    cached_outline = get_cached_outline(session_meta)

    broadcast("session:started", %{
      session_key: session_key,
      drivers: drivers,
      session_meta: session_meta
    })

    if cached_outline != [] do
      broadcast("track_outline:update", cached_outline)
    end

    # Fetch historical data from that point
    send(self(), {:fetch_historical, from_timestamp})

    {:noreply,
     %{state | drivers: drivers, session_meta: session_meta, track_outline: cached_outline}}
  end

  @impl true
  def handle_info({:poll, :locations}, %{tracking: true, session_key: sk} = state) do
    if state.mqtt_live and MQTTStream.connected?() do
      schedule_poll(:locations)
      {:noreply, state}
    else
      location_params = build_incremental_or_recent_params(sk, state.last_location_ts, 120)

      new_state =
        case DataProvider.get_location(location_params) do
          {:ok, data} when is_list(data) and data != [] ->
            locations = process_locations(data)
            last_ts = get_latest_timestamp(data)
            broadcast("locations:update", locations)
            %{state | locations: locations, last_location_ts: last_ts}

          _ ->
            state
        end

      # Fetch car telemetry at a lower cadence to reduce rate-limit pressure.
      now_ms = System.monotonic_time(:millisecond)

      should_poll_car_data =
        is_nil(new_state.last_car_poll_at) or
          now_ms - new_state.last_car_poll_at >= @car_data_poll_ms

      new_state =
        if should_poll_car_data do
          car_data_params =
            build_car_data_params(sk, new_state.last_drs_ts, 30, new_state.focus_driver)

          next_state = %{new_state | last_car_poll_at: now_ms}

          case DataProvider.get_car_data(car_data_params) do
            {:ok, data} when is_list(data) and data != [] ->
              drs = process_drs(data)
              merged_drs = Map.merge(next_state.drs || %{}, drs)
              last_ts = get_latest_timestamp(data)
              broadcast("drs:update", merged_drs)
              %{next_state | drs: merged_drs, last_drs_ts: last_ts}

            _ ->
              next_state
          end
        else
          new_state
        end

      schedule_poll(:locations)
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:poll, :timing}, %{tracking: true, session_key: sk} = state) do
    new_state = state

    # Fetch laps
    new_state =
      case DataProvider.get_laps(build_params(sk, state.last_lap_ts)) do
        {:ok, data} when is_list(data) and data != [] ->
          laps = process_laps(data, state.laps)
          last_ts = get_latest_timestamp(data)
          {best_sectors, personal_best_sectors} = compute_best_sectors(laps)
          broadcast("laps:update", laps)
          broadcast("sectors:update", %{best: best_sectors, personal: personal_best_sectors})

          %{
            new_state
            | laps: laps,
              last_lap_ts: last_ts,
              best_sectors: best_sectors,
              personal_best_sectors: personal_best_sectors
          }

        _ ->
          new_state
      end

    # Fetch intervals
    new_state =
      case DataProvider.get_intervals(build_params(sk, state.last_interval_ts)) do
        {:ok, data} when is_list(data) and data != [] ->
          intervals = process_intervals(data)
          last_ts = get_latest_timestamp(data)
          broadcast("intervals:update", intervals)
          %{new_state | intervals: intervals, last_interval_ts: last_ts}

        _ ->
          new_state
      end

    # Fetch positions
    new_state =
      case DataProvider.get_position(build_params(sk, state.last_position_ts)) do
        {:ok, data} when is_list(data) and data != [] ->
          positions = process_positions(data)
          last_ts = get_latest_timestamp(data)
          broadcast("positions:update", positions)
          %{new_state | positions: positions, last_position_ts: last_ts}

        _ ->
          new_state
      end

    schedule_poll(:timing)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:poll, :race_control}, %{tracking: true, session_key: sk} = state) do
    new_state =
      case DataProvider.get_race_control(build_params(sk, state.last_race_control_ts)) do
        {:ok, data} when is_list(data) and data != [] ->
          merged =
            (state.race_control ++ data)
            |> Enum.uniq_by(fn msg ->
              {msg["date"], msg["message"], msg["driver_number"]}
            end)
            |> Enum.take(-30)

          broadcast("race_control:new", data)
          broadcast("race_control:update", merged)

          %{state | race_control: merged, last_race_control_ts: get_latest_timestamp(data)}

        _ ->
          state
      end

    # Also fetch weather
    new_state =
      case DataProvider.get_weather(%{session_key: sk}) do
        {:ok, [latest | _]} ->
          broadcast("weather:update", latest)
          %{new_state | weather: latest}

        _ ->
          new_state
      end

    # Fetch stints (tyre compound data)
    new_state =
      case DataProvider.get_stints(%{session_key: sk}) do
        {:ok, data} when is_list(data) and data != [] ->
          stints = process_stints(data)
          broadcast("stints:update", stints)
          %{new_state | stints: stints}

        _ ->
          new_state
      end

    # Fetch team radio
    new_state =
      case DataProvider.get_team_radio(build_params(sk, new_state.last_radio_ts)) do
        {:ok, data} when is_list(data) and data != [] ->
          radio = process_team_radio(data, new_state.team_radio)
          last_ts = get_latest_timestamp(data)
          broadcast("team_radio:update", radio)
          %{new_state | team_radio: radio, last_radio_ts: last_ts}

        _ ->
          new_state
      end

    schedule_poll(:race_control)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:poll, _}, state) do
    # Not tracking, ignore
    {:noreply, state}
  end

  @impl true
  def handle_info({:fetch_historical, from_timestamp}, %{session_key: sk} = state) do
    Logger.info("Fetching historical data from #{from_timestamp}")

    # Fetch all data from the given timestamp
    # OpenF1 uses operator suffixes in param NAMES: date>, date<
    params = [{"session_key", sk}, {"date>", from_timestamp}]

    with {:ok, laps} <- DataProvider.get_laps(params),
         {:ok, positions} <- DataProvider.get_position(params),
         {:ok, locations} <- DataProvider.get_location(params) do
      processed_laps = process_laps(laps, %{})
      processed_positions = process_positions(positions)
      processed_locations = process_locations(locations)

      broadcast("replay:data", %{
        laps: processed_laps,
        positions: processed_positions,
        locations: processed_locations
      })

      new_state = %{
        state
        | laps: processed_laps,
          positions: processed_positions,
          locations: processed_locations
      }

      # Start live polling from now
      schedule_poll(:locations)
      schedule_poll(:timing)
      schedule_poll(:race_control)

      {:noreply, new_state}
    else
      _ ->
        Logger.error("Failed to fetch historical data")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:fetch_track_outline, %{session_key: sk, drivers: drivers} = state)
      when is_integer(sk) and map_size(drivers) > 0 do
    # For live sessions, try a few drivers individually in a bounded window.
    # This avoids loading huge all-driver location datasets into memory.
    now = DateTime.utc_now()
    from = DateTime.add(now, -420, :second)
    from_str = DateTime.to_iso8601(from)
    to_str = DateTime.to_iso8601(now)

    outline = build_outline_from_driver_candidates(sk, drivers, from_str, to_str)

    if outline != [] do
      Logger.info("SessionServer fetched track outline: #{length(outline)} points")
      broadcast("track_outline:update", outline)
      cache_outline(state.session_meta, outline)
      {:noreply, %{state | track_outline: outline}}
    else
      # Not enough usable data yet — retry in 30 seconds
      Process.send_after(self(), :fetch_track_outline, 30_000)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:fetch_track_outline, state), do: {:noreply, state}

  # -- Private Helpers --

  defp build_track_outline(data) do
    outline =
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

            cond do
              dist < 20 -> acc
              dist > 5000 -> acc
              true -> [%{x: x, y: y} | acc]
            end
        end
      end)
      |> Enum.reverse()

    outline = maybe_extract_closed_segment(outline)

    if valid_outline?(outline), do: outline, else: []
  end

  defp build_outline_from_driver_candidates(session_key, drivers, from_str, to_str) do
    drivers
    |> Map.keys()
    |> Enum.sort()
    |> Enum.take(12)
    |> Enum.reduce_while([], fn driver_num, _acc ->
      case DataProvider.get_location_for_driver(session_key, driver_num, from_str, to_str) do
        {:ok, data} when is_list(data) and length(data) > 100 ->
          outline = build_track_outline(data)

          if outline != [] do
            {:halt, outline}
          else
            {:cont, []}
          end

        _ ->
          {:cont, []}
      end
    end)
  end

  defp valid_outline?(outline) do
    if length(outline) < 120 do
      false
    else
      xs = Enum.map(outline, & &1.x)
      ys = Enum.map(outline, & &1.y)
      range_x = Enum.max(xs) - Enum.min(xs)
      range_y = Enum.max(ys) - Enum.min(ys)

      max(range_x, range_y) > 2_000
    end
  end

  defp maybe_extract_closed_segment(points) do
    n = length(points)

    if n < 200 do
      points
    else
      by_idx = points |> Enum.with_index() |> Map.new(fn {p, i} -> {i, p} end)

      max_start = min(n - 120, 60)

      best =
        Enum.reduce(0..max_start, {nil, nil, :infinity}, fn i, {bi, bj, bd} ->
          start = Map.fetch!(by_idx, i)

          {candidate_j, candidate_d} =
            Enum.reduce((i + 80)..(n - 1), {nil, bd}, fn j, {cj, cd} ->
              pt = Map.fetch!(by_idx, j)
              dx = start.x - pt.x
              dy = start.y - pt.y
              d = :math.sqrt(dx * dx + dy * dy)

              if d < cd, do: {j, d}, else: {cj, cd}
            end)

          if candidate_j != nil and candidate_d < bd do
            {i, candidate_j, candidate_d}
          else
            {bi, bj, bd}
          end
        end)

      case best do
        {i, j, d} when not is_nil(i) and not is_nil(j) and d < 800 ->
          Enum.slice(points, i..j)

        _ ->
          points
      end
    end
  end

  defp get_cached_outline(%{circuit_key: key}) when is_integer(key),
    do: TrackOutlineCache.get(key)

  defp get_cached_outline(_), do: []

  defp cache_outline(%{circuit_key: key}, outline) when is_integer(key) and is_list(outline) do
    TrackOutlineCache.put(key, outline)
  end

  defp cache_outline(_, _), do: :ok

  defp reset_session_state(state, session_key) do
    %{
      state
      | session_key: session_key,
        tracking: true,
        replay_mode: false,
        replay_from: nil,
        drivers: %{},
        positions: [],
        locations: %{},
        laps: %{},
        intervals: %{},
        race_control: [],
        weather: nil,
        stints: %{},
        best_sectors: %{s1: nil, s2: nil, s3: nil},
        personal_best_sectors: %{},
        drs: %{},
        team_radio: [],
        last_location_ts: nil,
        last_lap_ts: nil,
        last_interval_ts: nil,
        last_position_ts: nil,
        last_drs_ts: nil,
        last_car_poll_at: nil,
        last_radio_ts: nil,
        last_race_control_ts: nil,
        mqtt_live: false,
        focus_driver: nil,
        session_meta: nil,
        track_outline: []
    }
  end

  defp fetch_session_meta(session_key) do
    case DataProvider.get_sessions(%{session_key: session_key}) do
      {:ok, [session | _]} ->
        meeting_meta = fetch_meeting_metadata(session)
        circuit_info = fetch_circuit_info(meeting_meta.circuit_info_url)

        %{
          date_start: session["date_start"],
          date_end: session["date_end"],
          session_type: session["session_type"],
          session_name: session["session_name"],
          meeting_key: session["meeting_key"],
          year: session["year"],
          circuit_key: session["circuit_key"],
          circuit_short_name: session["circuit_short_name"],
          country_name: session["country_name"],
          location: session["location"],
          circuit_image: meeting_meta.circuit_image,
          country_flag: meeting_meta.country_flag,
          circuit_info_url: meeting_meta.circuit_info_url,
          circuit_rotation: circuit_info.rotation,
          circuit_path: circuit_info.path,
          circuit_corners: circuit_info.corners,
          circuit_marshal_lights: circuit_info.marshal_lights,
          circuit_marshal_sectors: circuit_info.marshal_sectors
        }

      _ ->
        nil
    end
  end

  defp session_ended?(date_end_str) do
    case DateTime.from_iso8601(date_end_str) do
      {:ok, dt, _} -> DateTime.compare(dt, DateTime.utc_now()) == :lt
      _ -> false
    end
  end

  defp fetch_meeting_metadata(session) do
    meeting_key = session["meeting_key"]

    meeting =
      case meeting_key do
        key when is_integer(key) ->
          case DataProvider.get_meetings(%{meeting_key: key}) do
            {:ok, [meeting | _]} -> meeting
            _ -> nil
          end

        _ ->
          nil
      end

    meeting =
      if is_map(meeting) do
        meeting
      else
        case DataProvider.get_meetings(%{
               year: session["year"],
               circuit_key: session["circuit_key"]
             }) do
          {:ok, [fallback | _]} -> fallback
          _ -> %{}
        end
      end

    %{
      circuit_image: meeting["circuit_image"],
      country_flag: meeting["country_flag"],
      circuit_info_url: meeting["circuit_info_url"]
    }
  end

  defp fetch_circuit_info(url) when is_binary(url) and url != "" do
    case Req.get(url,
           headers: [{"user-agent", "Mozilla/5.0"}],
           retry: :transient,
           retry_delay: fn attempt -> min(Integer.pow(2, attempt - 1) * 500, 4_000) end,
           max_retries: 3
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        %{
          rotation: body["rotation"],
          path: normalize_circuit_path(body),
          corners: normalize_circuit_markers(body["corners"]),
          marshal_lights: normalize_circuit_markers(body["marshalLights"]),
          marshal_sectors: normalize_circuit_markers(body["marshalSectors"])
        }

      _ ->
        %{
          rotation: nil,
          path: [],
          corners: [],
          marshal_lights: [],
          marshal_sectors: []
        }
    end
  end

  defp fetch_circuit_info(_url) do
    %{
      rotation: nil,
      path: [],
      corners: [],
      marshal_lights: [],
      marshal_sectors: []
    }
  end

  defp normalize_circuit_markers(markers) when is_list(markers) do
    markers
    |> Enum.map(fn marker ->
      pos = marker["trackPosition"] || %{}

      %{
        x: pos["x"],
        y: pos["y"],
        number: marker["number"],
        letter: marker["letter"],
        angle: marker["angle"],
        distance: marker["length"]
      }
    end)
    |> Enum.filter(fn m -> is_number(m.x) and is_number(m.y) end)
    |> Enum.sort_by(&(&1.distance || 0.0))
  end

  defp normalize_circuit_markers(_), do: []

  defp normalize_circuit_path(body) when is_map(body) do
    xs = body["x"]
    ys = body["y"]

    if is_list(xs) and is_list(ys) and xs != [] and ys != [] do
      count = min(length(xs), length(ys))

      xs
      |> Enum.take(count)
      |> Enum.zip(Enum.take(ys, count))
      |> Enum.map(fn {x, y} -> %{x: x, y: y} end)
      |> Enum.filter(fn p -> is_number(p.x) and is_number(p.y) end)
    else
      []
    end
  end

  defp normalize_circuit_path(_), do: []

  defp fetch_drivers(session_key) do
    case DataProvider.get_drivers(%{session_key: session_key}) do
      {:ok, drivers} when is_list(drivers) ->
        Map.new(drivers, fn d ->
          {d["driver_number"],
           %{
             number: d["driver_number"],
             code: d["name_acronym"],
             full_name: d["full_name"],
             team: d["team_name"],
             team_colour: d["team_colour"],
             headshot_url: d["headshot_url"]
           }}
        end)

      _ ->
        %{}
    end
  end

  defp process_locations(data) do
    # Group by driver, keep latest position for each
    data
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

  defp process_laps(data, existing_laps) do
    Enum.reduce(data, existing_laps, fn lap, acc ->
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
  end

  defp process_intervals(data) do
    data
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

  defp process_positions(data) do
    data
    |> Enum.group_by(& &1["driver_number"])
    |> Enum.map(fn {driver_num, entries} ->
      latest = Enum.max_by(entries, & &1["date"])
      %{driver_number: driver_num, position: latest["position"]}
    end)
    |> Enum.sort_by(& &1.position)
  end

  defp process_stints(data) do
    # Group by driver, keep latest stint (highest stint_number) per driver
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
  end

  defp process_team_radio(data, existing_radio) do
    new_entries =
      Enum.map(data, fn r ->
        %{
          driver_number: r["driver_number"],
          recording_url: r["recording_url"],
          date: r["date"]
        }
      end)

    # Append new entries, keep last 20
    (existing_radio ++ new_entries)
    |> Enum.uniq_by(& &1.recording_url)
    |> Enum.take(-20)
  end

  defp process_drs(data) do
    # Group by driver, keep latest telemetry snapshot per driver.
    # DRS values: 0-1 = off/unknown, 8 = eligible, 10-14 = active/open
    data
    |> Enum.group_by(& &1["driver_number"])
    |> Map.new(fn {driver_num, entries} ->
      latest = Enum.max_by(entries, & &1["date"])
      drs_value = latest["drs"] || 0

      {driver_num,
       %{
         drs: drs_value,
         active: drs_value >= 10,
         eligible: drs_value == 8,
         speed: latest["speed"],
         throttle: latest["throttle"],
         brake: latest["brake"],
         gear: latest["n_gear"],
         rpm: latest["rpm"]
       }}
    end)
  end

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

  defp build_params(session_key, nil), do: %{session_key: session_key}

  defp build_params(session_key, last_ts),
    do: [{"session_key", session_key}, {"date>", last_ts}]

  defp build_incremental_or_recent_params(session_key, nil, lookback_seconds)
       when is_integer(lookback_seconds) and lookback_seconds > 0 do
    from_iso =
      DateTime.utc_now()
      |> DateTime.add(-lookback_seconds, :second)
      |> DateTime.to_iso8601()

    [{"session_key", session_key}, {"date>", from_iso}]
  end

  defp build_incremental_or_recent_params(session_key, last_ts, _lookback_seconds),
    do: build_params(session_key, last_ts)

  defp build_car_data_params(session_key, last_ts, lookback_seconds, focus_driver) do
    base = build_incremental_or_recent_params(session_key, last_ts, lookback_seconds)

    if is_integer(focus_driver) do
      [{"driver_number", focus_driver} | base]
    else
      base
    end
  end

  defp maybe_start_mqtt_stream(session_key) when is_integer(session_key) do
    if MQTTStream.available?() do
      MQTTStream.start_stream(session_key)
      true
    else
      false
    end
  end

  defp maybe_start_mqtt_stream(_), do: false

  defp get_latest_timestamp(data) do
    data
    |> Enum.map(& &1["date"])
    |> Enum.filter(& &1)
    |> Enum.max(fn -> nil end)
  end

  defp schedule_poll(:locations) do
    Process.send_after(self(), {:poll, :locations}, @location_poll_ms)
  end

  defp schedule_poll(:timing) do
    Process.send_after(self(), {:poll, :timing}, @poll_interval_ms)
  end

  defp schedule_poll(:race_control) do
    Process.send_after(self(), {:poll, :race_control}, 15_000)
  end

  defp broadcast(event, data) do
    Phoenix.PubSub.broadcast(@pubsub, "f1:live", {event, data})
  end
end
