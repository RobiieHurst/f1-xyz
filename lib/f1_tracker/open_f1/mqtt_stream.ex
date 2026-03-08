defmodule F1Tracker.OpenF1.MQTTStream do
  @moduledoc """
  Server-side MQTT consumer for OpenF1 live topics.

  Streams `v1/location` and `v1/car_data` into Phoenix PubSub events so
  LiveView clients can consume real-time updates without REST polling.
  """

  use GenServer
  require Logger

  alias F1Tracker.OpenF1.TokenManager
  alias F1Tracker.F1.SessionServer

  @pubsub F1Tracker.PubSub
  @host ~c"mqtt.openf1.org"
  @port 8883
  @flush_interval_ms 250
  @reconnect_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_stream(session_key) when is_integer(session_key) do
    GenServer.cast(__MODULE__, {:start_stream, session_key})
  end

  def stop_stream do
    GenServer.cast(__MODULE__, :stop_stream)
  end

  def connected? do
    GenServer.call(__MODULE__, :connected?)
  end

  @impl true
  def init(_opts) do
    {:ok,
     %{
       client: nil,
       session_key: nil,
       connected: false,
       pending_locations: %{},
       pending_car_data: %{},
       flush_ref: nil,
       reconnect_ref: nil
     }}
  end

  @impl true
  def handle_call(:connected?, _from, state), do: {:reply, state.connected, state}

  @impl true
  def handle_cast({:start_stream, session_key}, state) do
    state = cancel_reconnect(state)
    state = cancel_flush(state)
    state = disconnect_client(state)
    {:noreply, connect(state, session_key)}
  end

  @impl true
  def handle_cast(:stop_stream, state) do
    state = cancel_reconnect(state)
    state = cancel_flush(state)
    {:noreply, disconnect_client(%{state | session_key: nil})}
  end

  @impl true
  def handle_info(:flush, state) do
    state = %{state | flush_ref: nil}

    if map_size(state.pending_locations) > 0 do
      Phoenix.PubSub.broadcast(@pubsub, "f1:live", {"locations:update", state.pending_locations})
      SessionServer.mqtt_locations_update(state.pending_locations)
    end

    if map_size(state.pending_car_data) > 0 do
      Phoenix.PubSub.broadcast(@pubsub, "f1:live", {"drs:update", state.pending_car_data})
      SessionServer.mqtt_drs_update(state.pending_car_data)
    end

    {:noreply, %{state | pending_locations: %{}, pending_car_data: %{}}}
  end

  @impl true
  def handle_info(:reconnect, state) do
    {:noreply, connect(%{state | reconnect_ref: nil}, state.session_key)}
  end

  @impl true
  def handle_info({:publish, packet}, %{session_key: session_key} = state) do
    topic = Map.get(packet, :topic)
    payload = Map.get(packet, :payload)

    state =
      with topic when is_binary(topic) <- normalize_topic(topic),
           payload when is_binary(payload) <- normalize_payload(payload),
           {:ok, msg} <- Jason.decode(payload),
           true <- int_value(msg["session_key"]) == session_key do
        case topic do
          "v1/location" ->
            update_location_pending(state, msg)

          "v1/car_data" ->
            update_car_pending(state, msg)

          _ ->
            state
        end
      else
        _ -> state
      end

    {:noreply, maybe_schedule_flush(state)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{client: pid} = state) do
    Logger.warning("MQTT stream disconnected: #{inspect(reason)}")
    {:noreply, schedule_reconnect(%{state | client: nil, connected: false})}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp connect(state, nil), do: state

  defp connect(state, session_key) do
    case TokenManager.get_token() do
      token when is_binary(token) and token != "" ->
        client_id = "f1_tracker_#{session_key}_#{System.unique_integer([:positive])}"

        opts = [
          {:host, @host},
          {:port, @port},
          {:ssl, true},
          {:ssl_opts, [{:verify, :verify_none}]},
          {:clientid, String.to_charlist(client_id)},
          {:username, ~c"f1_tracker"},
          {:password, String.to_charlist(token)},
          {:clean_start, true},
          {:keepalive, 60}
        ]

        with {:ok, client} <- :emqtt.start_link(opts),
             {:ok, _props} <- :emqtt.connect(client),
             {:ok, _, _} <- :emqtt.subscribe(client, [{"v1/location", 0}, {"v1/car_data", 0}]) do
          Process.monitor(client)
          Logger.info("MQTT stream connected for session #{session_key}")
          %{state | client: client, session_key: session_key, connected: true}
        else
          error ->
            Logger.warning("MQTT stream connect failed: #{inspect(error)}")
            schedule_reconnect(%{state | client: nil, session_key: session_key, connected: false})
        end

      _ ->
        Logger.warning("MQTT stream skipped: no OpenF1 token available")
        %{state | session_key: session_key, connected: false}
    end
  end

  defp disconnect_client(%{client: nil} = state), do: %{state | connected: false}

  defp disconnect_client(state) do
    safe_disconnect(state.client)

    %{state | client: nil, connected: false, pending_locations: %{}, pending_car_data: %{}}
  end

  defp normalize_topic(topic) when is_binary(topic), do: topic
  defp normalize_topic(topic) when is_list(topic), do: List.to_string(topic)
  defp normalize_topic(_), do: nil

  defp normalize_payload(payload) when is_binary(payload), do: payload
  defp normalize_payload(payload) when is_list(payload), do: List.to_string(payload)
  defp normalize_payload(_), do: nil

  defp update_location_pending(state, msg) do
    driver = int_value(msg["driver_number"])

    if is_integer(driver) do
      loc = %{
        x: msg["x"],
        y: msg["y"],
        z: msg["z"],
        date: msg["date"]
      }

      %{state | pending_locations: Map.put(state.pending_locations, driver, loc)}
    else
      state
    end
  end

  defp update_car_pending(state, msg) do
    driver = int_value(msg["driver_number"])

    if is_integer(driver) do
      drs_value = msg["drs"] || 0

      snapshot = %{
        drs: drs_value,
        active: drs_value >= 10,
        eligible: drs_value == 8,
        speed: msg["speed"],
        throttle: msg["throttle"],
        brake: msg["brake"],
        gear: msg["n_gear"],
        rpm: msg["rpm"]
      }

      %{state | pending_car_data: Map.put(state.pending_car_data, driver, snapshot)}
    else
      state
    end
  end

  defp maybe_schedule_flush(%{flush_ref: nil} = state) do
    ref = Process.send_after(self(), :flush, @flush_interval_ms)
    %{state | flush_ref: ref}
  end

  defp maybe_schedule_flush(state), do: state

  defp schedule_reconnect(%{reconnect_ref: nil, session_key: session_key} = state)
       when is_integer(session_key) do
    ref = Process.send_after(self(), :reconnect, @reconnect_ms)
    %{state | reconnect_ref: ref}
  end

  defp schedule_reconnect(state), do: state

  defp cancel_reconnect(%{reconnect_ref: nil} = state), do: state

  defp cancel_reconnect(state) do
    Process.cancel_timer(state.reconnect_ref)
    %{state | reconnect_ref: nil}
  end

  defp cancel_flush(%{flush_ref: nil} = state), do: state

  defp cancel_flush(state) do
    Process.cancel_timer(state.flush_ref)
    %{state | flush_ref: nil}
  end

  defp int_value(value) when is_integer(value), do: value

  defp int_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp int_value(_), do: nil

  defp safe_disconnect(client) do
    try do
      _ = :emqtt.disconnect(client)
      _ = :emqtt.stop(client)
      :ok
    catch
      :exit, _ -> :ok
    end
  end
end
