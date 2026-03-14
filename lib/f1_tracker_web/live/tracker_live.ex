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
      # Fetch session state asynchronously to avoid blocking mount
      send(self(), :load_current_state)
    end

    socket =
      socket
      |> assign(:sessions, [])
      |> assign(:selected_session, nil)
      |> assign(:session_meta, nil)
      |> assign(:tracking, false)
      |> assign(:drivers, %{})
      |> assign(:locations, %{})
      |> assign(:positions, [])
      |> assign(:laps, %{})
      |> assign(:intervals, %{})
      |> assign(:race_control, [])
      |> assign(:weather, nil)
      |> assign(:stints, %{})
      |> assign(:best_sectors, %{s1: nil, s2: nil, s3: nil})
      |> assign(:personal_best_sectors, %{})
      |> assign(:drs, %{})
      |> assign(:team_radio, [])
      |> assign(:replay_from, nil)
      |> assign(:loading, false)
      |> assign(:all_sessions, [])
      |> assign(:filter_search, "")
      |> assign(:filter_type, "all")
      |> assign(:show_timing, false)
      |> assign(:replay_active, false)
      |> assign(:replay_paused, false)
      |> assign(:replay_speed, 1)
      |> assign(:replay_progress, 0.0)
      |> assign(:replay_cursor, nil)
      |> assign(:replay_loading, false)
      |> assign(:previous_positions, %{})
      |> assign(:selected_driver, nil)
      |> assign(:replay_seek_timer, nil)
      |> assign(:replay_seek_pending, nil)
      |> assign(:replay_seek_last_sent, nil)

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

        filtered =
          filter_sessions(formatted, socket.assigns.filter_search, socket.assigns.filter_type)

        {:noreply, assign(socket, all_sessions: formatted, sessions: filtered, loading: false)}

      {:error, _} ->
        {:noreply, assign(socket, loading: false)}
    end
  end

  @impl true
  def handle_event("filter_sessions", %{"value" => search}, socket) do
    filtered = filter_sessions(socket.assigns.all_sessions, search, socket.assigns.filter_type)
    {:noreply, assign(socket, filter_search: search, sessions: filtered)}
  end

  @impl true
  def handle_event("filter_type", %{"type" => type}, socket) do
    filtered = filter_sessions(socket.assigns.all_sessions, socket.assigns.filter_search, type)
    {:noreply, assign(socket, filter_type: type, sessions: filtered)}
  end

  @impl true
  def handle_event("track_session", %{"session_key" => sk}, socket) do
    session_key = String.to_integer(sk)
    SessionServer.track_session(session_key)

    # Cast is async — loading state until we get "session:started" via PubSub
    {:noreply,
     assign(socket,
       selected_session: session_key,
       loading: true
     )}
  end

  @impl true
  def handle_event("stop_tracking", _params, socket) do
    if socket.assigns.replay_seek_timer,
      do: Process.cancel_timer(socket.assigns.replay_seek_timer)

    SessionServer.set_focus_driver(nil)
    SessionServer.stop_tracking()
    F1Tracker.F1.ReplayServer.stop_replay()

    {:noreply,
     assign(socket,
       tracking: false,
       replay_active: false,
       replay_paused: false,
       replay_progress: 0.0,
       selected_driver: nil,
       replay_seek_timer: nil,
       replay_seek_pending: nil,
       replay_seek_last_sent: nil
     )
     |> push_event("follow_driver", %{driver_number: nil})}
  end

  @impl true
  def handle_event("toggle_timing", _params, socket) do
    {:noreply, assign(socket, show_timing: !socket.assigns.show_timing)}
  end

  @impl true
  def handle_event("select_driver", %{"driver_number" => driver_number}, socket) do
    number = String.to_integer(driver_number)

    selected_driver =
      if socket.assigns.selected_driver == number do
        nil
      else
        number
      end

    SessionServer.set_focus_driver(selected_driver)

    {:noreply,
     socket
     |> assign(:selected_driver, selected_driver)
     |> push_event("follow_driver", %{driver_number: selected_driver})}
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

  @impl true
  def handle_event("replay_toggle_pause", _params, socket) do
    F1Tracker.F1.ReplayServer.toggle_pause()
    {:noreply, socket}
  end

  @impl true
  def handle_event("replay_set_speed", %{"speed" => speed}, socket) do
    F1Tracker.F1.ReplayServer.set_speed(String.to_integer(speed))
    {:noreply, socket}
  end

  @impl true
  def handle_event("replay_seek", %{"value" => value}, socket) do
    ratio = String.to_float(value)

    if socket.assigns.replay_seek_timer do
      Process.cancel_timer(socket.assigns.replay_seek_timer)
    end

    timer = Process.send_after(self(), {:apply_replay_seek, ratio}, 180)

    {:noreply,
     socket
     |> assign(:replay_seek_timer, timer)
     |> assign(:replay_seek_pending, ratio)}
  end

  @impl true
  def handle_event("replay_nudge", %{"seconds" => seconds}, socket) do
    if socket.assigns.replay_active do
      F1Tracker.F1.ReplayServer.seek_by(String.to_integer(seconds))
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("replay_shortcut", %{"key" => key, "repeat" => "true"}, socket)
      when key in ["ArrowLeft", "ArrowRight"] do
    {:noreply, socket}
  end

  @impl true
  def handle_event("replay_shortcut", %{"key" => "ArrowLeft"}, socket) do
    if socket.assigns.replay_active do
      F1Tracker.F1.ReplayServer.seek_by(-5)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("replay_shortcut", %{"key" => "ArrowRight"}, socket) do
    if socket.assigns.replay_active do
      F1Tracker.F1.ReplayServer.seek_by(5)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("replay_shortcut", _params, socket), do: {:noreply, socket}

  # -- PubSub Handlers --

  @impl true
  def handle_info(
        {"session:started", %{session_key: sk, drivers: drivers, session_meta: session_meta}},
        socket
      ) do
    SessionServer.set_focus_driver(nil)

    {:noreply,
     socket
     |> assign(:selected_session, sk)
     |> assign(:session_meta, session_meta)
     |> assign(:drivers, drivers)
     |> assign(:selected_driver, nil)
     |> assign(:tracking, true)
     |> assign(:loading, false)
     |> push_event("drivers_loaded", %{drivers: drivers})
     |> push_event("session_meta", %{session: session_meta})
     |> push_event("follow_driver", %{driver_number: nil})}
  end

  @impl true
  def handle_info({"session:started", %{session_key: sk, drivers: drivers}}, socket) do
    SessionServer.set_focus_driver(nil)

    {:noreply,
     socket
     |> assign(:selected_session, sk)
     |> assign(:drivers, drivers)
     |> assign(:selected_driver, nil)
     |> assign(:tracking, true)
     |> assign(:loading, false)
     |> push_event("drivers_loaded", %{drivers: drivers})
     |> push_event("follow_driver", %{driver_number: nil})}
  end

  @impl true
  def handle_info({"locations:update", locations}, socket) do
    {:noreply,
     socket
     |> assign(:locations, locations)
     |> push_event("locations_update", %{
       locations:
         encode_locations(locations, socket.assigns.drivers, socket.assigns.drs, %{
           positions: socket.assigns.positions,
           laps: socket.assigns.laps,
           intervals: socket.assigns.intervals,
           stints: socket.assigns.stints
         })
     })}
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
    new_position_map = positions_to_map(positions)

    overtake_events =
      detect_overtakes(socket.assigns.previous_positions, new_position_map, socket)

    socket =
      socket
      |> assign(:positions, positions)
      |> assign(:previous_positions, new_position_map)

    socket =
      if overtake_events != [] do
        push_event(socket, "track_events", %{events: overtake_events})
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({"race_control:update", messages}, socket) do
    {:noreply, assign(socket, :race_control, Enum.take(messages, -10))}
  end

  @impl true
  def handle_info({"race_control:new", messages}, socket) do
    merged =
      (socket.assigns.race_control ++ messages)
      |> Enum.uniq_by(fn msg ->
        {msg["date"] || msg[:date], msg["message"] || msg[:message],
         msg["driver_number"] || msg[:driver_number]}
      end)
      |> Enum.take(-10)

    incident_events = build_incident_events(messages, socket)

    socket = assign(socket, :race_control, merged)

    socket =
      if incident_events != [] do
        push_event(socket, "track_events", %{events: incident_events})
      else
        socket
      end

    {:noreply, socket}
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
  def handle_info({"stints:update", stints}, socket) do
    {:noreply, assign(socket, :stints, stints)}
  end

  @impl true
  def handle_info({"drs:update", drs}, socket) do
    {:noreply, assign(socket, :drs, drs)}
  end

  @impl true
  def handle_info({"sectors:update", %{best: best, personal: personal}}, socket) do
    {:noreply,
     socket
     |> assign(:best_sectors, best)
     |> assign(:personal_best_sectors, personal)}
  end

  @impl true
  def handle_info({"team_radio:update", radio}, socket) do
    {:noreply, assign(socket, :team_radio, radio)}
  end

  @impl true
  def handle_info({"replay:state", replay_state}, socket) do
    {:noreply,
     socket
     |> assign(:replay_active, replay_state.active)
     |> assign(:replay_paused, replay_state.paused)
     |> assign(:replay_speed, replay_state.speed)
     |> assign(:replay_progress, replay_state.progress)
     |> assign(:replay_cursor, replay_state[:replay_cursor])
     |> assign(:replay_loading, replay_state.loading)}
  end

  @impl true
  def handle_info({"replay:finished", _}, socket) do
    {:noreply,
     socket
     |> assign(:replay_paused, true)
     |> assign(:replay_progress, 1.0)}
  end

  @impl true
  def handle_info({:apply_replay_seek, ratio}, socket) do
    current_pending = socket.assigns.replay_seek_pending
    last_sent = socket.assigns.replay_seek_last_sent

    should_send =
      socket.assigns.replay_active and
        is_float(current_pending) and
        abs(current_pending - ratio) < 0.0005 and
        (is_nil(last_sent) or abs(ratio - last_sent) >= 0.001)

    if should_send do
      F1Tracker.F1.ReplayServer.seek(ratio)
    end

    {:noreply,
     socket
     |> assign(:replay_seek_timer, nil)
     |> assign(:replay_seek_pending, nil)
     |> assign(:replay_seek_last_sent, if(should_send, do: ratio, else: last_sent))}
  end

  @impl true
  def handle_info({"track_outline:update", outline}, socket) do
    {:noreply, push_event(socket, "track_outline", %{points: outline})}
  end

  @impl true
  def handle_info(:load_current_state, socket) do
    state = try_get_state()
    replay_state = F1Tracker.F1.ReplayServer.get_state()

    socket =
      socket
      |> assign(:selected_session, state[:session_key])
      |> assign(:session_meta, state[:session_meta])
      |> assign(:tracking, state[:tracking] || false)
      |> assign(:drivers, state[:drivers] || %{})
      |> assign(:locations, state[:locations] || %{})
      |> assign(:positions, state[:positions] || [])
      |> assign(:laps, state[:laps] || %{})
      |> assign(:intervals, state[:intervals] || %{})
      |> assign(:race_control, state[:race_control] || [])
      |> assign(:weather, state[:weather])
      |> assign(:stints, state[:stints] || %{})
      |> assign(:best_sectors, state[:best_sectors] || %{s1: nil, s2: nil, s3: nil})
      |> assign(:personal_best_sectors, state[:personal_best_sectors] || %{})
      |> assign(:drs, state[:drs] || %{})
      |> assign(:team_radio, state[:team_radio] || [])
      |> assign(:previous_positions, positions_to_map(state[:positions] || []))

    if state[:tracking] && map_size(state[:drivers] || %{}) > 0 do
      socket = push_event(socket, "drivers_loaded", %{drivers: state[:drivers]})

      socket =
        if state[:session_meta] do
          push_event(socket, "session_meta", %{session: state[:session_meta]})
        else
          socket
        end

      socket =
        cond do
          is_list(state[:track_outline]) and state[:track_outline] != [] ->
            push_event(socket, "track_outline", %{points: state[:track_outline]})

          is_list(replay_state[:track_outline]) and replay_state[:track_outline] != [] ->
            push_event(socket, "track_outline", %{points: replay_state[:track_outline]})

          true ->
            socket
        end

      socket =
        push_event(socket, "follow_driver", %{driver_number: socket.assigns.selected_driver})

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  # -- Helpers --

  defp try_get_state do
    case GenServer.whereis(SessionServer) do
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

  defp encode_locations(locations, drivers, drs, timing) do
    # Build a position lookup: driver_number => position
    position_lookup =
      (timing[:positions] || [])
      |> Enum.into(%{}, fn p ->
        {p[:driver_number] || p["driver_number"], p[:position] || p["position"]}
      end)

    Map.new(locations, fn {driver_num, loc} ->
      driver = lookup_driver_key(drivers, driver_num) || %{}
      driver_drs = lookup_driver_key(drs, driver_num) || %{}

      # Latest lap data
      latest =
        case lookup_driver_key(timing[:laps] || %{}, driver_num) do
          nil -> nil
          laps -> latest_valid_lap(laps)
        end

      # Interval/gap data
      interval_data = lookup_driver_key(timing[:intervals] || %{}, driver_num) || %{}

      # Current stint (tyre info)
      stint = lookup_driver_key(timing[:stints] || %{}, driver_num) || %{}

      {to_string(driver_num),
       Map.merge(loc, %{
         code: driver[:code] || to_string(driver_num),
         team_colour: driver[:team_colour] || "FFFFFF",
         headshot_url: driver[:headshot_url],
         drs_active: driver_drs[:active] || false,
         drs_eligible: driver_drs[:eligible] || false,
         speed: driver_drs[:speed],
         throttle: driver_drs[:throttle],
         brake: driver_drs[:brake],
         gear: driver_drs[:gear],
         rpm: driver_drs[:rpm],
         # Timing data for map labels
         position: lookup_driver_key(position_lookup, driver_num),
         last_lap: format_lap_time_short(latest && latest.lap_duration),
         gap: format_gap_short(interval_data[:gap_to_leader]),
         interval: format_gap_short(interval_data[:interval]),
         compound: tyre_compound_short(stint[:compound])
       })}
    end)
  end

  defp lookup_driver_key(map, key) when is_map(map) do
    Map.get(map, key) ||
      Map.get(map, to_string(key)) ||
      if is_binary(key), do: Map.get(map, parse_int(key)), else: nil
  end

  defp lookup_driver_key(_, _), do: nil

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp positions_to_map(positions) do
    Map.new(positions, fn p ->
      {p[:driver_number] || p["driver_number"], p[:position] || p["position"]}
    end)
  end

  defp detect_overtakes(previous_positions, new_positions, socket) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    new_positions
    |> Enum.reduce([], fn {driver, new_pos}, acc ->
      old_pos = Map.get(previous_positions, driver)

      cond do
        is_nil(old_pos) or is_nil(new_pos) or new_pos >= old_pos ->
          acc

        true ->
          victim =
            Enum.find_value(new_positions, fn {other_driver, other_new_pos} ->
              other_old_pos = Map.get(previous_positions, other_driver)

              if other_driver != driver and other_old_pos == new_pos and other_new_pos == old_pos do
                other_driver
              else
                nil
              end
            end)

          case Map.get(socket.assigns.locations, driver) do
            %{x: x, y: y} when is_number(x) and is_number(y) ->
              driver_code =
                (Map.get(socket.assigns.drivers, driver) || %{})[:code] || to_string(driver)

              label =
                if victim do
                  victim_code =
                    (Map.get(socket.assigns.drivers, victim) || %{})[:code] || to_string(victim)

                  "OVERTAKE #{driver_code} > #{victim_code}"
                else
                  "OVERTAKE #{driver_code}"
                end

              [
                %{
                  id: "overtake-#{driver}-#{old_pos}-#{new_pos}-#{timestamp}",
                  type: "overtake",
                  x: x,
                  y: y,
                  label: label,
                  ts: timestamp
                }
                | acc
              ]

            _ ->
              acc
          end
      end
    end)
  end

  defp build_incident_events(messages, socket) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    messages
    |> Enum.filter(&incident_message?/1)
    |> Enum.reduce([], fn msg, acc ->
      msg_text = msg["message"] || msg[:message] || "Incident"
      driver_number = msg["driver_number"] || msg[:driver_number] || parse_car_number(msg_text)

      location =
        if is_integer(driver_number) do
          Map.get(socket.assigns.locations, driver_number)
        else
          nil
        end

      case location do
        %{x: x, y: y} when is_number(x) and is_number(y) ->
          label =
            msg_text
            |> String.slice(0, 42)
            |> then(fn t -> if String.length(msg_text) > 42, do: t <> "...", else: t end)

          [
            %{
              id: "incident-#{driver_number || "na"}-#{msg["date"] || msg[:date] || timestamp}",
              type: "incident",
              x: x,
              y: y,
              label: label,
              ts: timestamp
            }
            | acc
          ]

        _ ->
          acc
      end
    end)
  end

  defp incident_message?(msg) do
    text = (msg["message"] || msg[:message] || "") |> String.downcase()

    String.contains?(text, "crash") or
      String.contains?(text, "accident") or
      String.contains?(text, "collision") or
      String.contains?(text, "stopped") or
      String.contains?(text, "red flag")
  end

  defp parse_car_number(message) when is_binary(message) do
    case Regex.run(~r/car\s+(\d{1,2})/i, message) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  defp parse_car_number(_), do: nil

  defp format_lap_time_short(nil), do: nil

  defp format_lap_time_short(duration) when is_float(duration) do
    if valid_lap_duration?(duration) do
      format_lap_duration(duration, 2)
    else
      nil
    end
  end

  defp format_lap_time_short(_), do: nil

  defp format_gap_short(nil), do: nil
  defp format_gap_short(gap) when is_number(gap), do: "+#{:io_lib.format("~.1f", [gap])}"
  defp format_gap_short(gap), do: to_string(gap)

  defp tyre_compound_short(nil), do: nil
  defp tyre_compound_short("SOFT"), do: "S"
  defp tyre_compound_short("MEDIUM"), do: "M"
  defp tyre_compound_short("HARD"), do: "H"
  defp tyre_compound_short("INTERMEDIATE"), do: "I"
  defp tyre_compound_short("WET"), do: "W"
  defp tyre_compound_short(_), do: nil

  # -- Session filter helpers --

  defp filter_sessions(sessions, search, type) do
    sessions
    |> filter_by_type(type)
    |> filter_by_search(search)
  end

  defp filter_by_type(sessions, "all"), do: sessions

  defp filter_by_type(sessions, type) do
    Enum.filter(sessions, fn s -> s.type == type end)
  end

  defp filter_by_search(sessions, nil), do: sessions
  defp filter_by_search(sessions, ""), do: sessions

  defp filter_by_search(sessions, search) do
    search_down = String.downcase(search)

    Enum.filter(sessions, fn s ->
      String.contains?(String.downcase(s.circuit || ""), search_down) or
        String.contains?(String.downcase(s.country || ""), search_down) or
        String.contains?(String.downcase(s.name || ""), search_down)
    end)
  end

  @session_types [
    "all",
    "Race",
    "Qualifying",
    "Practice"
  ]

  def session_types, do: @session_types

  def type_label("all"), do: "All"
  def type_label(type), do: type

  def session_type_badge("Race"), do: "bg-red-900/60 text-red-300"
  def session_type_badge("Qualifying"), do: "bg-blue-900/60 text-blue-300"
  def session_type_badge("Sprint"), do: "bg-orange-900/60 text-orange-300"
  def session_type_badge("Sprint Shootout"), do: "bg-orange-900/60 text-orange-300"
  def session_type_badge("Practice"), do: "bg-gray-700/60 text-gray-300"
  def session_type_badge(_), do: "bg-gray-700/60 text-gray-300"

  def format_session_date(nil), do: ""

  def format_session_date(date_str) when is_binary(date_str) do
    case DateTime.from_iso8601(date_str) do
      {:ok, dt, _} ->
        Calendar.strftime(dt, "%b %d, %Y · %H:%M")

      _ ->
        String.slice(date_str, 0, 16)
    end
  end

  def format_session_date(_), do: ""

  # -- Timing helpers for template --

  def format_lap_time(nil), do: "-"

  def format_lap_time(duration) when is_float(duration) do
    if valid_lap_duration?(duration) do
      format_lap_duration(duration, 3)
    else
      "-"
    end
  end

  def format_lap_time(duration), do: to_string(duration)

  def format_telemetry_value(nil), do: "-"
  def format_telemetry_value(value) when is_integer(value), do: Integer.to_string(value)
  def format_telemetry_value(value) when is_float(value), do: Float.round(value, 1) |> to_string()
  def format_telemetry_value(value), do: to_string(value)

  def format_gap(nil), do: "-"
  def format_gap(gap) when is_number(gap), do: "+#{:io_lib.format("~.3f", [gap])}"
  def format_gap(gap), do: to_string(gap)

  def latest_lap(laps, driver_number) do
    case Map.get(laps, driver_number) do
      nil -> nil
      driver_laps -> latest_valid_lap(driver_laps)
    end
  end

  defdelegate race_control_class(msg), to: F1TrackerWeb.TrackerLiveHelpers

  @doc "Returns CSS class for sector time colouring"
  def sector_colour(nil, _personal_best, _overall_best), do: "text-gray-400"
  def sector_colour(_time, nil, nil), do: "text-gray-400"

  def sector_colour(time, personal_best, overall_best) do
    cond do
      overall_best && time <= overall_best -> "text-purple-400"
      personal_best && time <= personal_best -> "text-green-400"
      true -> "text-yellow-400"
    end
  end

  def format_sector(nil), do: "-"

  def format_sector(duration) when is_float(duration) do
    :io_lib.format("~.3f", [duration]) |> to_string() |> String.trim()
  end

  def format_sector(duration), do: to_string(duration)

  def tyre_colour(nil), do: "bg-gray-500"
  def tyre_colour("SOFT"), do: "bg-red-500"
  def tyre_colour("MEDIUM"), do: "bg-yellow-400"
  def tyre_colour("HARD"), do: "bg-white"
  def tyre_colour("INTERMEDIATE"), do: "bg-green-500"
  def tyre_colour("WET"), do: "bg-blue-500"
  def tyre_colour(_), do: "bg-gray-500"

  def tyre_label(nil), do: "?"
  def tyre_label("SOFT"), do: "S"
  def tyre_label("MEDIUM"), do: "M"
  def tyre_label("HARD"), do: "H"
  def tyre_label("INTERMEDIATE"), do: "I"
  def tyre_label("WET"), do: "W"
  def tyre_label(_), do: "?"

  def tyre_age(stint, laps, driver_number) do
    current_lap =
      case latest_lap(laps, driver_number) do
        nil -> stint[:lap_start] || 0
        lap -> lap.lap_number || 0
      end

    start = stint[:lap_start] || 0
    age_at_start = stint[:tyre_age] || 0
    age_at_start + max(current_lap - start, 0)
  end

  def best_lap(laps, driver_number) do
    case Map.get(laps, driver_number) do
      nil ->
        nil

      driver_laps ->
        driver_laps
        |> Enum.filter(fn lap -> valid_lap_duration?(lap.lap_duration) end)
        |> Enum.min_by(& &1.lap_duration, fn -> nil end)
    end
  end

  defp latest_valid_lap(driver_laps) do
    driver_laps
    |> Enum.reverse()
    |> Enum.find(fn lap -> valid_lap_duration?(lap.lap_duration) end)
  end

  defp valid_lap_duration?(duration) when is_float(duration),
    do: duration >= 20.0 and duration <= 300.0

  defp valid_lap_duration?(_), do: false

  defp format_lap_duration(duration, 2) do
    total_cs = round(duration * 100)
    minutes = div(total_cs, 6_000)
    remaining_cs = rem(total_cs, 6_000)
    seconds = div(remaining_cs, 100)
    centis = rem(remaining_cs, 100)

    formatted_seconds = :io_lib.format("~2..0B", [seconds]) |> to_string()
    formatted_centis = :io_lib.format("~2..0B", [centis]) |> to_string()

    if minutes > 0 do
      "#{minutes}:#{formatted_seconds}.#{formatted_centis}"
    else
      "#{seconds}.#{formatted_centis}"
    end
  end

  defp format_lap_duration(duration, 3) do
    total_ms = round(duration * 1_000)
    minutes = div(total_ms, 60_000)
    remaining_ms = rem(total_ms, 60_000)
    seconds = div(remaining_ms, 1_000)
    millis = rem(remaining_ms, 1_000)

    formatted_seconds = :io_lib.format("~2..0B", [seconds]) |> to_string()
    formatted_millis = :io_lib.format("~3..0B", [millis]) |> to_string()

    if minutes > 0 do
      "#{minutes}:#{formatted_seconds}.#{formatted_millis}"
    else
      "#{seconds}.#{formatted_millis}"
    end
  end

  def format_replay_cursor(nil), do: "--:--:--"

  def format_replay_cursor(cursor_str) when is_binary(cursor_str) do
    case DateTime.from_iso8601(cursor_str) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> "--:--:--"
    end
  end

  def format_replay_cursor(_), do: "--:--:--"
end
