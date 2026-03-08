defmodule F1Tracker.F1.SessionServerMQTTTest do
  use ExUnit.Case, async: false

  alias F1Tracker.F1.SessionServer

  setup do
    pid = GenServer.whereis(SessionServer)
    assert is_pid(pid)

    original_state = :sys.get_state(pid)

    on_exit(fn ->
      :sys.replace_state(pid, fn _ -> original_state end)
    end)

    :ok
  end

  test "mqtt_locations_update merges live locations into server state" do
    pid = GenServer.whereis(SessionServer)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | tracking: true,
          replay_mode: false,
          locations: %{1 => %{x: 1.0, y: 2.0, z: 0.0, date: "2026-01-01T00:00:00Z"}}
      }
    end)

    SessionServer.mqtt_locations_update(%{
      16 => %{x: 10.0, y: 20.0, z: 0.0, date: "2026-01-01T00:00:01Z"}
    })

    state = :sys.get_state(pid)

    assert state.locations[1].x == 1.0
    assert state.locations[16].x == 10.0
  end

  test "mqtt_drs_update merges live telemetry into server state" do
    pid = GenServer.whereis(SessionServer)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | tracking: true,
          replay_mode: false,
          drs: %{1 => %{drs: 0, active: false, speed: 250}}
      }
    end)

    SessionServer.mqtt_drs_update(%{
      16 => %{drs: 10, active: true, speed: 300, throttle: 100, brake: 0, gear: 8, rpm: 12_000}
    })

    state = :sys.get_state(pid)

    assert state.drs[1].speed == 250
    assert state.drs[16].active
    assert state.drs[16].rpm == 12_000
  end

  test "mqtt updates are ignored outside live tracking mode" do
    pid = GenServer.whereis(SessionServer)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | tracking: true,
          replay_mode: true,
          locations: %{},
          drs: %{}
      }
    end)

    SessionServer.mqtt_locations_update(%{
      44 => %{x: 1.0, y: 1.0, z: 0.0, date: "2026-01-01T00:00:01Z"}
    })

    SessionServer.mqtt_drs_update(%{44 => %{drs: 10, active: true}})

    state = :sys.get_state(pid)

    assert state.locations == %{}
    assert state.drs == %{}
  end
end
