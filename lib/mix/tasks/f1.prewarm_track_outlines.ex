defmodule Mix.Tasks.F1.PrewarmTrackOutlines do
  @moduledoc """
  Prewarms and caches track outlines by circuit.

  Uses historical sessions to compute an outline per `circuit_key`, then stores
  them via `F1Tracker.F1.TrackOutlineCache`.

  ## Examples

      mix f1.prewarm_track_outlines
      mix f1.prewarm_track_outlines --years 2025,2024
      mix f1.prewarm_track_outlines --years 2025 --force

  """

  use Mix.Task

  alias F1Tracker.DataProvider
  alias F1Tracker.F1.TrackOutlineCache

  @shortdoc "Prewarm per-circuit track outlines cache"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [years: :string, force: :boolean]
      )

    years = parse_years(opts[:years])
    force? = opts[:force] || false

    Mix.shell().info("Prewarming track outlines for years: #{Enum.join(years, ", ")}")

    years
    |> fetch_sessions_for_years()
    |> pick_best_session_per_circuit()
    |> Enum.each(fn {circuit_key, session} ->
      run_for_circuit(circuit_key, session, force?)
    end)

    Mix.shell().info("Done prewarming track outlines")
  end

  defp run_for_circuit(circuit_key, session, force?) do
    cached = TrackOutlineCache.get(circuit_key)

    cond do
      cached != [] and not force? ->
        Mix.shell().info("skip circuit #{circuit_key}: cached")

      true ->
        session_key = session["session_key"]
        circuit = session["circuit_short_name"] || "unknown"
        Mix.shell().info("build circuit #{circuit_key} (#{circuit}) from session #{session_key}")

        case build_outline_for_session(session) do
          [] ->
            Mix.shell().error("  failed: no valid outline")

          outline ->
            TrackOutlineCache.put(circuit_key, outline)
            Mix.shell().info("  ok: #{length(outline)} points")
        end
    end
  end

  defp fetch_sessions_for_years(years) do
    Enum.flat_map(years, fn year ->
      case DataProvider.get_sessions(%{year: year}) do
        {:ok, sessions} when is_list(sessions) -> sessions
        _ -> []
      end
    end)
  end

  defp pick_best_session_per_circuit(sessions) do
    sessions
    |> Enum.filter(fn s ->
      is_integer(s["circuit_key"]) and
        s["session_type"] in ["Race", "Sprint", "Qualifying"] and
        is_binary(s["date_start"])
    end)
    |> Enum.group_by(& &1["circuit_key"])
    |> Enum.map(fn {circuit_key, group} ->
      best =
        group
        |> Enum.sort_by(&session_rank/1)
        |> List.first()

      {circuit_key, best}
    end)
  end

  defp session_rank(session) do
    type_rank =
      case session["session_type"] do
        "Race" -> 0
        "Sprint" -> 1
        "Qualifying" -> 2
        _ -> 9
      end

    # Prefer newer sessions inside same type class
    {type_rank, sort_date_key(session["date_start"]) * -1}
  end

  defp build_outline_for_session(session) do
    session_key = session["session_key"]

    with {:ok, drivers} <- fetch_driver_numbers(session_key),
         {:ok, dt, _} <- DateTime.from_iso8601(session["date_start"]) do
      windows = [
        {120, 420},
        {420, 420},
        {0, 420}
      ]

      Enum.reduce_while(windows, [], fn {offset, span}, _acc ->
        from_dt = DateTime.add(dt, offset, :second)
        to_dt = DateTime.add(from_dt, span, :second)

        from_str = DateTime.to_iso8601(from_dt)
        to_str = DateTime.to_iso8601(to_dt)

        outline =
          drivers
          |> Enum.take(12)
          |> Enum.reduce_while([], fn driver_num, _driver_acc ->
            case DataProvider.get_location_for_driver(session_key, driver_num, from_str, to_str) do
              {:ok, data} when is_list(data) and length(data) > 100 ->
                built = build_track_outline(data)
                if built != [], do: {:halt, built}, else: {:cont, []}

              _ ->
                {:cont, []}
            end
          end)

        if outline != [], do: {:halt, outline}, else: {:cont, []}
      end)
    else
      _ -> []
    end
  end

  defp fetch_driver_numbers(session_key) do
    case DataProvider.get_drivers(%{session_key: session_key}) do
      {:ok, drivers} when is_list(drivers) ->
        numbers =
          drivers
          |> Enum.map(& &1["driver_number"])
          |> Enum.filter(&is_integer/1)
          |> Enum.sort()

        case numbers do
          [] -> {:error, :no_drivers}
          _ -> {:ok, numbers}
        end

      _ ->
        {:error, :driver_fetch_failed}
    end
  end

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

  defp sort_date_key(nil), do: 0

  defp sort_date_key(date_str) do
    case DateTime.from_iso8601(date_str) do
      {:ok, dt, _} -> DateTime.to_unix(dt)
      _ -> 0
    end
  end

  defp parse_years(nil) do
    now = Date.utc_today().year
    [now, now - 1]
  end

  defp parse_years(raw) when is_binary(raw) do
    raw
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_integer/1)
    |> Enum.uniq()
  end
end
