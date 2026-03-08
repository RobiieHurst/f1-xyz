defmodule F1Tracker.Dev.MQTTSimulator do
  @moduledoc false

  alias F1Tracker.F1.SessionServer
  alias F1Tracker.OpenF1.MQTTStream

  @default_drivers [1, 16, 44, 55]

  def run(opts \\ []) do
    ticks = Keyword.get(opts, :ticks, 40)
    interval_ms = Keyword.get(opts, :interval_ms, 250)
    drivers = Keyword.get(opts, :drivers, @default_drivers)
    session_key = Keyword.get(opts, :session_key) || SessionServer.get_state().session_key

    with :ok <- validate_session_key(session_key),
         :ok <- validate_drivers(drivers),
         :ok <- validate_positive_integer(ticks, :ticks),
         :ok <- validate_positive_integer(interval_ms, :interval_ms),
         {:ok, stream_pid} <- mqtt_stream_pid(),
         :ok <- validate_stream_session(stream_pid, session_key) do
      IO.puts(
        "Simulating MQTT race feed: session=#{session_key} ticks=#{ticks} interval_ms=#{interval_ms} drivers=#{Enum.join(Enum.map(drivers, &Integer.to_string/1), ",")}"
      )

      Enum.each(0..(ticks - 1), fn tick ->
        ts = DateTime.utc_now() |> DateTime.add(tick, :second) |> DateTime.to_iso8601()

        Enum.each(drivers, fn driver_number ->
          publish_tick(stream_pid, session_key, driver_number, tick, ts)
        end)

        send(stream_pid, :flush)
        Process.sleep(interval_ms)
      end)

      IO.puts("MQTT simulation completed")
      :ok
    end
  end

  defp publish_tick(stream_pid, session_key, driver_number, tick, ts) do
    angle = tick / 8 + driver_number / 20
    radius = 1200 + rem(driver_number * 7, 150)

    x = Float.round(:math.cos(angle) * radius + 2500, 3)
    y = Float.round(:math.sin(angle) * radius + 1800, 3)

    speed = 210 + rem(tick * 3 + driver_number, 140)
    throttle = 55 + rem(tick * 5 + driver_number, 45)
    brake = rem(tick + driver_number, 9)
    gear = 5 + rem(tick, 4)
    rpm = 9500 + rem(tick * 137 + driver_number * 21, 3400)
    drs = if rem(tick + driver_number, 6) in [0, 1], do: 10, else: 8

    send_publish(stream_pid, "v1/location", %{
      "session_key" => session_key,
      "driver_number" => driver_number,
      "x" => x,
      "y" => y,
      "z" => 0.0,
      "date" => ts
    })

    send_publish(stream_pid, "v1/car_data", %{
      "session_key" => session_key,
      "driver_number" => driver_number,
      "drs" => drs,
      "speed" => speed,
      "throttle" => throttle,
      "brake" => brake,
      "n_gear" => gear,
      "rpm" => rpm,
      "date" => ts
    })
  end

  defp send_publish(stream_pid, topic, payload) do
    send(stream_pid, {:publish, %{topic: topic, payload: Jason.encode!(payload)}})
  end

  defp mqtt_stream_pid do
    case GenServer.whereis(MQTTStream) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> {:error, "MQTTStream is not running"}
    end
  end

  defp validate_stream_session(stream_pid, session_key) do
    state = :sys.get_state(stream_pid)

    if state.session_key == session_key do
      :ok
    else
      {:error,
       "MQTT stream session mismatch (stream=#{inspect(state.session_key)} app=#{session_key}). Start tracking the session first."}
    end
  end

  defp validate_session_key(session_key) when is_integer(session_key), do: :ok

  defp validate_session_key(_),
    do: {:error, "No active session key. Start tracking first or pass :session_key."}

  defp validate_drivers(drivers) when is_list(drivers) do
    if drivers != [] and Enum.all?(drivers, &is_integer/1) do
      :ok
    else
      {:error, "Drivers must be a non-empty list of integers"}
    end
  end

  defp validate_drivers(_), do: {:error, "Drivers must be a list"}

  defp validate_positive_integer(value, _name) when is_integer(value) and value > 0, do: :ok
  defp validate_positive_integer(_value, name), do: {:error, "#{name} must be a positive integer"}
end
