defmodule F1Tracker.F1.SessionServer do
  @moduledoc """
  GenServer that polls OpenF1 for live session data and broadcasts
  updates via PubSub. Manages state for the current active session.
  """
  use GenServer
  require Logger

  alias F1Tracker.OpenF1.Client

  @poll_interval_ms 1_000
  @location_poll_ms 500
  @pubsub F1Tracker.PubSub

  # -- Public API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Start tracking a specific session"
  def track_session(session_key) do
    GenServer.call(__MODULE__, {:track_session, session_key})
  end

  @doc "Stop tracking"
  def stop_tracking do
    GenServer.call(__MODULE__, :stop_tracking)
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
    GenServer.call(__MODULE__, {:replay_from, session_key, from_timestamp})
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
      last_location_ts: nil,
      last_lap_ts: nil,
      last_interval_ts: nil,
      replay_mode: false,
      replay_from: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:track_session, session_key}, _from, state) do
    Logger.info("Starting to track session: #{session_key}")

    # Fetch initial driver data
    drivers = fetch_drivers(session_key)

    new_state = %{
      state
      | session_key: session_key,
        tracking: true,
        drivers: drivers,
        replay_mode: false,
        replay_from: nil
    }

    # Start polling
    schedule_poll(:locations)
    schedule_poll(:timing)
    schedule_poll(:race_control)

    broadcast("session:started", %{session_key: session_key, drivers: drivers})

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:stop_tracking, _from, state) do
    Logger.info("Stopping session tracking")
    {:reply, :ok, %{state | tracking: false}}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:replay_from, session_key, from_timestamp}, _from, state) do
    Logger.info("Starting replay from #{from_timestamp} for session #{session_key}")

    drivers = fetch_drivers(session_key)

    new_state = %{
      state
      | session_key: session_key,
        tracking: true,
        drivers: drivers,
        replay_mode: true,
        replay_from: from_timestamp
    }

    # Fetch historical data from that point
    send(self(), {:fetch_historical, from_timestamp})

    {:reply, :ok, new_state}
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
          broadcast("laps:update", laps)
          %{new_state | laps: laps, last_lap_ts: last_ts}

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
      case Client.get_position(build_params(sk, nil)) do
        {:ok, data} when is_list(data) and data != [] ->
          positions = process_positions(data)
          broadcast("positions:update", positions)
          %{new_state | positions: positions}

        _ ->
          new_state
      end

    schedule_poll(:timing)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:poll, :race_control}, %{tracking: true, session_key: sk} = state) do
    new_state =
      case Client.get_race_control(%{session_key: sk}) do
        {:ok, data} when is_list(data) ->
          broadcast("race_control:update", data)
          %{state | race_control: data}

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
    params = %{session_key: sk, date: ">#{from_timestamp}"}

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

  # -- Private Helpers --

  defp fetch_drivers(session_key) do
    case Client.get_drivers(%{session_key: session_key}) do
      {:ok, drivers} when is_list(drivers) ->
        Map.new(drivers, fn d ->
          {d["driver_number"], %{
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
      {driver_num, %{
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
      {driver_num, %{
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

  defp build_params(session_key, nil), do: %{session_key: session_key}
  defp build_params(session_key, last_ts), do: %{session_key: session_key, date: ">#{last_ts}"}

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
    Process.send_after(self(), {:poll, :race_control}, 5_000)
  end

  defp broadcast(event, data) do
    Phoenix.PubSub.broadcast(@pubsub, "f1:live", {event, data})
  end
end
