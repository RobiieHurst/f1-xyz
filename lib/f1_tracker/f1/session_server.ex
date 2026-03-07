defmodule F1Tracker.F1.SessionServer do
  @moduledoc """
  GenServer that polls OpenF1 for live session data and broadcasts
  updates via PubSub. Manages state for the current active session.
  """
  use GenServer
  require Logger

  alias F1Tracker.OpenF1.Client

  @poll_interval_ms 5_000
  @location_poll_ms 2_000
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
    Client.get_sessions()
  end

  @doc "Start replay from a specific timestamp"
  def replay_from(session_key, from_timestamp) do
    GenServer.cast(__MODULE__, {:replay_from, session_key, from_timestamp})
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
    {:noreply, %{state | tracking: false}}
  end

  @impl true
  def handle_cast({:replay_from, session_key, from_timestamp}, state) do
    Logger.info("Starting replay from #{from_timestamp} for session #{session_key}")
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

    completed? =
      case session_meta do
        %{date_end: date_end} when not is_nil(date_end) -> session_ended?(date_end)
        _ -> false
      end

    new_state = %{state | drivers: drivers, session_meta: session_meta}

    if completed? do
      Logger.info("Completed session detected, starting replay")
      # Delegate to ReplayServer for completed sessions
      F1Tracker.F1.ReplayServer.start_replay(session_key, session_meta, drivers)

      broadcast("session:started", %{
        session_key: session_key,
        drivers: drivers,
        session_meta: session_meta
      })

      {:noreply, new_state}
    else
      # Live session — start incremental polling
      schedule_poll(:locations)
      schedule_poll(:timing)
      schedule_poll(:race_control)

      broadcast("session:started", %{
        session_key: session_key,
        drivers: drivers,
        session_meta: session_meta
      })

      # Fetch track outline in background for live sessions that have been running
      send(self(), :fetch_track_outline)

      now_iso = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      {:noreply, %{new_state | last_race_control_ts: now_iso}}
    end
  end

  @impl true
  def handle_info({:init_replay, session_key, from_timestamp}, state) do
    drivers = fetch_drivers(session_key)
    session_meta = fetch_session_meta(session_key)

    broadcast("session:started", %{
      session_key: session_key,
      drivers: drivers,
      session_meta: session_meta
    })

    # Fetch historical data from that point
    send(self(), {:fetch_historical, from_timestamp})

    {:noreply, %{state | drivers: drivers, session_meta: session_meta}}
  end

  @impl true
  def handle_info({:poll, :locations}, %{tracking: true, session_key: sk} = state) do
    new_state =
      case Client.get_location(build_params(sk, state.last_location_ts)) do
        {:ok, data} when is_list(data) and data != [] ->
          locations = process_locations(data)
          last_ts = get_latest_timestamp(data)
          broadcast("locations:update", locations)
          %{state | locations: locations, last_location_ts: last_ts}

        _ ->
          state
      end

    # Fetch DRS data alongside locations
    new_state =
      case Client.get_car_data(build_params(sk, new_state.last_drs_ts)) do
        {:ok, data} when is_list(data) and data != [] ->
          drs = process_drs(data)
          last_ts = get_latest_timestamp(data)
          broadcast("drs:update", drs)
          %{new_state | drs: drs, last_drs_ts: last_ts}

        _ ->
          new_state
      end

    schedule_poll(:locations)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:poll, :timing}, %{tracking: true, session_key: sk} = state) do
    new_state = state

    # Fetch laps
    new_state =
      case Client.get_laps(build_params(sk, state.last_lap_ts)) do
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
      case Client.get_intervals(build_params(sk, state.last_interval_ts)) do
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
      case Client.get_position(build_params(sk, state.last_position_ts)) do
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
      case Client.get_race_control(build_params(sk, state.last_race_control_ts)) do
        {:ok, data} when is_list(data) and data != [] ->
          merged =
            (state.race_control ++ data)
            |> Enum.uniq_by(fn msg ->
              {msg["date"], msg["message"], msg["driver_number"]}
            end)
            |> Enum.take(-30)

          broadcast("race_control:update", merged)

          %{state | race_control: merged, last_race_control_ts: get_latest_timestamp(data)}

        _ ->
          state
      end

    # Also fetch weather
    new_state =
      case Client.get_weather(%{session_key: sk}) do
        {:ok, [latest | _]} ->
          broadcast("weather:update", latest)
          %{new_state | weather: latest}

        _ ->
          new_state
      end

    # Fetch stints (tyre compound data)
    new_state =
      case Client.get_stints(%{session_key: sk}) do
        {:ok, data} when is_list(data) and data != [] ->
          stints = process_stints(data)
          broadcast("stints:update", stints)
          %{new_state | stints: stints}

        _ ->
          new_state
      end

    # Fetch team radio
    new_state =
      case Client.get_team_radio(build_params(sk, new_state.last_radio_ts)) do
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

    with {:ok, laps} <- Client.get_laps(params),
         {:ok, positions} <- Client.get_position(params),
         {:ok, locations} <- Client.get_location(params) do
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
    # For live sessions, fetch a wider recent window and derive an outline
    # from the best driver trajectory in that window.
    now = DateTime.utc_now()
    from = DateTime.add(now, -900, :second)
    from_str = DateTime.to_iso8601(from)
    to_str = DateTime.to_iso8601(now)

    case Client.get_location_range(sk, from_str, to_str) do
      {:ok, data} when is_list(data) and length(data) > 100 ->
        outline = build_track_outline_from_locations(data)

        if outline != [] do
          Logger.info("SessionServer fetched track outline: #{length(outline)} points")
          broadcast("track_outline:update", outline)
          {:noreply, %{state | track_outline: outline}}
        else
          # Outline shape not reliable yet — retry later
          Process.send_after(self(), :fetch_track_outline, 30_000)
          {:noreply, state}
        end

      _ ->
        # Not enough data yet — retry in 30 seconds
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

    if valid_outline?(outline), do: outline, else: []
  end

  defp build_track_outline_from_locations(data) do
    data
    |> Enum.group_by(& &1["driver_number"])
    |> Enum.sort_by(fn {_driver, entries} -> length(entries) end, :desc)
    |> Enum.reduce_while([], fn {_driver, entries}, _acc ->
      outline = build_track_outline(entries)

      if outline != [] do
        {:halt, outline}
      else
        {:cont, []}
      end
    end)
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
        last_radio_ts: nil,
        last_race_control_ts: nil,
        session_meta: nil,
        track_outline: []
    }
  end

  defp fetch_session_meta(session_key) do
    case Client.get_sessions(%{session_key: session_key}) do
      {:ok, [session | _]} ->
        %{
          date_start: session["date_start"],
          date_end: session["date_end"],
          session_type: session["session_type"],
          session_name: session["session_name"],
          circuit_key: session["circuit_key"],
          circuit_short_name: session["circuit_short_name"],
          country_name: session["country_name"],
          location: session["location"]
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

  defp fetch_drivers(session_key) do
    case Client.get_drivers(%{session_key: session_key}) do
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
    # Group by driver, keep latest DRS state per driver
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
         speed: latest["speed"]
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
