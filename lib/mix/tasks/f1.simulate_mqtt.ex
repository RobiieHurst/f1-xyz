defmodule Mix.Tasks.F1.SimulateMqtt do
  @moduledoc """
  Simulates a live MQTT race feed into the running app process.

  Start tracking a live session first, then run this task from the same node
  (for example inside `iex -S mix phx.server`):

      F1Tracker.Dev.MQTTSimulator.run()

  CLI examples:

      mix f1.simulate_mqtt
      mix f1.simulate_mqtt --ticks 80 --interval-ms 150
      mix f1.simulate_mqtt --drivers 1,16,44,55 --session-key 9158
  """

  use Mix.Task

  alias F1Tracker.Dev.MQTTSimulator

  @shortdoc "Simulate MQTT location/car_data feed"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [session_key: :integer, ticks: :integer, interval_ms: :integer, drivers: :string]
      )

    sim_opts =
      []
      |> maybe_put(:session_key, opts[:session_key])
      |> maybe_put(:ticks, opts[:ticks])
      |> maybe_put(:interval_ms, opts[:interval_ms])
      |> maybe_put(:drivers, parse_drivers(opts[:drivers]))

    case MQTTSimulator.run(sim_opts) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("f1.simulate_mqtt failed: #{reason}")
    end
  end

  defp parse_drivers(nil), do: nil

  defp parse_drivers(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn s ->
      case Integer.parse(s) do
        {int, ""} -> int
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
