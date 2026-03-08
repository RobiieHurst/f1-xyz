defmodule F1Tracker.OpenF1.MQTTStreamSimulationTest do
  use ExUnit.Case, async: false

  alias F1Tracker.F1.SessionServer
  alias F1Tracker.OpenF1.MQTTStream

  @pubsub F1Tracker.PubSub
  @session_key 999_001

  setup do
    session_pid = GenServer.whereis(SessionServer)
    stream_pid = GenServer.whereis(MQTTStream)

    assert is_pid(session_pid)
    assert is_pid(stream_pid)

    original_session_state = :sys.get_state(session_pid)
    original_stream_state = :sys.get_state(stream_pid)

    :sys.replace_state(session_pid, fn state ->
      %{state | tracking: true, replay_mode: false, locations: %{}, drs: %{}}
    end)

    :sys.replace_state(stream_pid, fn state ->
      %{
        state
        | client: nil,
          session_key: @session_key,
          connected: true,
          pending_locations: %{},
          pending_car_data: %{},
          flush_ref: nil,
          reconnect_ref: nil
      }
    end)

    Phoenix.PubSub.subscribe(@pubsub, "f1:live")

    on_exit(fn ->
      :sys.replace_state(session_pid, fn _ -> original_session_state end)
      :sys.replace_state(stream_pid, fn _ -> original_stream_state end)
    end)

    :ok
  end

  test "simulated race tick broadcasts latest MQTT state" do
    stream_pid = GenServer.whereis(MQTTStream)

    # Driver 1 sends two location points before flush; latest should win.
    send_publish("v1/location", %{
      "session_key" => Integer.to_string(@session_key),
      "driver_number" => "1",
      "x" => 100.0,
      "y" => 200.0,
      "z" => 0.0,
      "date" => "2026-03-08T12:00:00Z"
    })

    send_publish("v1/location", %{
      "session_key" => @session_key,
      "driver_number" => 1,
      "x" => 101.5,
      "y" => 201.5,
      "z" => 0.0,
      "date" => "2026-03-08T12:00:01Z"
    })

    send_publish("v1/location", %{
      "session_key" => @session_key,
      "driver_number" => 16,
      "x" => 300.0,
      "y" => 400.0,
      "z" => 0.0,
      "date" => "2026-03-08T12:00:01Z"
    })

    send_publish("v1/car_data", %{
      "session_key" => @session_key,
      "driver_number" => 1,
      "drs" => 10,
      "speed" => 312,
      "throttle" => 99,
      "brake" => 0,
      "n_gear" => 8,
      "rpm" => 12_200,
      "date" => "2026-03-08T12:00:01Z"
    })

    send_publish("v1/car_data", %{
      "session_key" => @session_key,
      "driver_number" => 16,
      "drs" => 8,
      "speed" => 298,
      "throttle" => 94,
      "brake" => 2,
      "n_gear" => 8,
      "rpm" => 11_900,
      "date" => "2026-03-08T12:00:01Z"
    })

    send(stream_pid, :flush)

    assert_receive {"locations:update", locations}, 1_000
    assert_receive {"drs:update", telemetry}, 1_000

    assert locations[1].x == 101.5
    assert locations[16].y == 400.0

    assert telemetry[1].active
    assert telemetry[1].speed == 312
    assert telemetry[16].eligible
    refute telemetry[16].active
  end

  test "simulated race ignores packets from other session" do
    stream_pid = GenServer.whereis(MQTTStream)

    send_publish("v1/location", %{
      "session_key" => 123_456,
      "driver_number" => 44,
      "x" => 10.0,
      "y" => 20.0,
      "z" => 0.0,
      "date" => "2026-03-08T12:00:00Z"
    })

    send(stream_pid, :flush)

    refute_receive {"locations:update", _}, 300
    refute_receive {"drs:update", _}, 300
  end

  defp send_publish(topic, payload) do
    stream_pid = GenServer.whereis(MQTTStream)
    encoded = Jason.encode!(payload)
    send(stream_pid, {:publish, %{topic: topic, payload: encoded}})
  end
end
