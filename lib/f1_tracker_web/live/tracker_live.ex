defmodule F1TrackerWeb.TrackerLive do
  @moduledoc """
  Main LiveView for the F1 real-time tracker.
  Shows track map with car positions and live timing tower.
  """
  use F1TrackerWeb, :live_view

  alias F1Tracker.F1.SessionServer

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(F1Tracker.PubSub, "f1:live")
    end

    # Try to get current state if session is active
    state = try_get_state()

    socket =
      socket
      |> assign(:sessions, [])
      |> assign(:selected_session, state[:session_key])
      |> assign(:tracking, state[:tracking] || false)
      |> assign(:drivers, state[:drivers] || %{})
      |> assign(:locations, state[:locations] || %{})
      |> assign(:positions, state[:positions] || [])
      |> assign(:laps, state[:laps] || %{})
      |> assign(:intervals, state[:intervals] || %{})
      |> assign(:race_control, state[:race_control] || [])
      |> assign(:weather, state[:weather])
      |> assign(:replay_from, nil)
      |> assign(:loading, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("load_sessions", _params, socket) do
    socket = assign(socket, :loading, true)

    case SessionServer.list_sessions() do
      {:ok, sessions} ->
        formatted =
          sessions
          |> Enum.map(fn s ->
            %{
              session_key: s["session_key"],
              name: s["session_name"],
              circuit: s["circuit_short_name"],
              country: s["country_name"],
              date: s["date_start"],
              type: s["session_type"],
              year: s["year"]
            }
          end)
          |> Enum.reverse()
          |> Enum.take(20)

        {:noreply, assign(socket, sessions: formatted, loading: false)}

      {:error, _} ->
        {:noreply, assign(socket, loading: false)}
    end
  end

  @impl true
  def handle_event("track_session", %{"session_key" => sk}, socket) do
    session_key = String.to_integer(sk)
    SessionServer.track_session(session_key)

    {:noreply,
     assign(socket,
       selected_session: session_key,
       tracking: true
     )}
  end

  @impl true
  def handle_event("stop_tracking", _params, socket) do
    SessionServer.stop_tracking()
    {:noreply, assign(socket, tracking: false)}
  end

  @impl true
  def handle_event("set_replay_from", %{"timestamp" => ts}, socket) do
    {:noreply, assign(socket, replay_from: ts)}
  end

  @impl true
  def handle_event("start_replay", _params, socket) do
    if socket.assigns.selected_session && socket.assigns.replay_from do
      SessionServer.replay_from(
        socket.assigns.selected_session,
        socket.assigns.replay_from
      )
    end

    {:noreply, socket}
  end

  # -- PubSub Handlers --

  @impl true
  def handle_info({"session:started", %{session_key: sk, drivers: drivers}}, socket) do
    {:noreply,
     socket
     |> assign(:selected_session, sk)
     |> assign(:drivers, drivers)
     |> assign(:tracking, true)
     |> push_event("drivers_loaded", %{drivers: drivers})}
  end

  @impl true
  def handle_info({"locations:update", locations}, socket) do
    {:noreply,
     socket
     |> assign(:locations, locations)
     |> push_event("locations_update", %{locations: encode_locations(locations, socket.assigns.drivers)})}
  end

  @impl true
  def handle_info({"laps:update", laps}, socket) do
    {:noreply, assign(socket, :laps, laps)}
  end

  @impl true
  def handle_info({"intervals:update", intervals}, socket) do
    {:noreply, assign(socket, :intervals, intervals)}
  end

  @impl true
  def handle_info({"positions:update", positions}, socket) do
    {:noreply, assign(socket, :positions, positions)}
  end

  @impl true
  def handle_info({"race_control:update", messages}, socket) do
    {:noreply, assign(socket, :race_control, Enum.take(messages, -10))}
  end

  @impl true
  def handle_info({"weather:update", weather}, socket) do
    {:noreply, assign(socket, :weather, weather)}
  end

  @impl true
  def handle_info({"replay:data", data}, socket) do
    {:noreply,
     socket
     |> assign(:laps, data.laps)
     |> assign(:positions, data.positions)
     |> assign(:locations, data.locations)
     |> push_event("replay_data", data)}
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  # -- Helpers --

  defp try_get_state do
    case GenServer.whereis(SessionServer) do
      nil -> %{}
      _pid -> SessionServer.get_state()
    end
  end

  defp encode_locations(locations, drivers) do
    Map.new(locations, fn {driver_num, loc} ->
      driver = Map.get(drivers, driver_num, %{})
      {to_string(driver_num), Map.merge(loc, %{
        code: driver[:code] || "???",
        team_colour: driver[:team_colour] || "FFFFFF"
      })}
    end)
  end

  # -- Timing helpers for template --

  def format_lap_time(nil), do: "-"
  def format_lap_time(duration) when is_float(duration) do
    minutes = trunc(duration / 60)
    seconds = duration - minutes * 60
    if minutes > 0 do
      "#{minutes}:#{:io_lib.format("~6.3f", [seconds])}"
    else
      :io_lib.format("~6.3f", [seconds]) |> to_string() |> String.trim()
    end
  end
  def format_lap_time(duration), do: to_string(duration)

  def format_gap(nil), do: "-"
  def format_gap(gap) when is_number(gap), do: "+#{:io_lib.format("~.3f", [gap])}"
  def format_gap(gap), do: to_string(gap)

  def latest_lap(laps, driver_number) do
    case Map.get(laps, driver_number) do
      nil -> nil
      driver_laps -> List.last(driver_laps)
    end
  end

  defdelegate race_control_class(msg), to: F1TrackerWeb.TrackerLiveHelpers

  def best_lap(laps, driver_number) do
    case Map.get(laps, driver_number) do
      nil ->
        nil

      driver_laps ->
        driver_laps
        |> Enum.filter(& &1.lap_duration)
        |> Enum.min_by(& &1.lap_duration, fn -> nil end)
    end
  end
end
