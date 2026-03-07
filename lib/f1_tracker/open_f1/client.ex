defmodule F1Tracker.OpenF1.Client do
  @moduledoc """
  HTTP client for the OpenF1 API.
  https://openf1.org
  """

  @base_url "https://api.openf1.org/v1"

  @doc """
  Fetch car location data (x, y, z coordinates).
  Used for plotting cars on the track map.
  """
  def get_location(params \\ %{}) do
    get("/location", params)
  end

  @doc """
  Fetch lap timing data for drivers.
  """
  def get_laps(params \\ %{}) do
    get("/laps", params)
  end

  @doc """
  Fetch driver information for a session.
  """
  def get_drivers(params \\ %{}) do
    get("/drivers", params)
  end

  @doc """
  Fetch available sessions (races, qualifying, practice).
  """
  def get_sessions(params \\ %{}) do
    get("/sessions", params)
  end

  @doc """
  Fetch meetings (event-level metadata, including circuit image).
  """
  def get_meetings(params \\ %{}) do
    get("/meetings", params)
  end

  @doc """
  Fetch position/ranking data.
  """
  def get_position(params \\ %{}) do
    get("/position", params)
  end

  @doc """
  Fetch pit stop data.
  """
  def get_pit(params \\ %{}) do
    get("/pit", params)
  end

  @doc """
  Fetch race control messages (flags, penalties, etc).
  """
  def get_race_control(params \\ %{}) do
    get("/race_control", params)
  end

  @doc """
  Fetch car telemetry data (speed, throttle, brake, gear, DRS).
  """
  def get_car_data(params \\ %{}) do
    get("/car_data", params)
  end

  @doc """
  Fetch interval/gap data between drivers.
  """
  def get_intervals(params \\ %{}) do
    get("/intervals", params)
  end

  @doc """
  Fetch team radio messages.
  """
  def get_team_radio(params \\ %{}) do
    get("/team_radio", params)
  end

  @doc """
  Fetch weather data for the session.
  """
  def get_weather(params \\ %{}) do
    get("/weather", params)
  end

  @doc """
  Fetch stint/tyre data.
  """
  def get_stints(params \\ %{}) do
    get("/stints", params)
  end

  @doc """
  Fetch location data with a date range (two date params with different operators).
  Accepts a keyword list of params to allow duplicate keys.
  """
  def get_location_range(session_key, from_iso, to_iso) do
    # OpenF1 uses operator suffixes in param NAMES: date>, date<, date>=, date<=
    # We use date> (exclusive) and date< (exclusive) to avoid overlap between chunks
    params = [{"session_key", session_key}, {"date>", from_iso}, {"date<", to_iso}]
    get("/location", params)
  end

  @doc """
  Fetch location data for a single driver in a date range.
  Used to build the track outline from one car's trajectory.
  """
  def get_location_for_driver(session_key, driver_number, from_iso, to_iso) do
    params = [
      {"session_key", session_key},
      {"driver_number", driver_number},
      {"date>", from_iso},
      {"date<", to_iso}
    ]

    get("/location", params)
  end

  # -- Private --

  defp get(path, params) do
    url = @base_url <> path
    headers = auth_headers()

    case Req.get(url,
           params: params,
           headers: headers,
           retry: :transient,
           retry_delay: &retry_delay/1,
           max_retries: 5
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Exponential backoff: 1s, 2s, 4s, 8s, 16s
  defp retry_delay(attempt) do
    delay = Integer.pow(2, attempt - 1) * 1_000
    min(delay, 16_000)
  end

  defp auth_headers do
    case F1Tracker.OpenF1.TokenManager.get_token() do
      nil -> []
      token -> [{"authorization", "Bearer #{token}"}]
    end
  end
end
