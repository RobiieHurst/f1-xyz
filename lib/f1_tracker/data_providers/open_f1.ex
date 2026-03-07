defmodule F1Tracker.DataProviders.OpenF1 do
  @moduledoc """
  Data provider implementation backed by OpenF1.
  """

  @behaviour F1Tracker.DataProviders.Provider

  alias F1Tracker.OpenF1.Client

  @impl true
  def get_location(params \\ %{}), do: Client.get_location(params)

  @impl true
  def get_laps(params \\ %{}), do: Client.get_laps(params)

  @impl true
  def get_drivers(params \\ %{}), do: Client.get_drivers(params)

  @impl true
  def get_sessions(params \\ %{}), do: Client.get_sessions(params)

  @impl true
  def get_position(params \\ %{}), do: Client.get_position(params)

  @impl true
  def get_pit(params \\ %{}), do: Client.get_pit(params)

  @impl true
  def get_race_control(params \\ %{}), do: Client.get_race_control(params)

  @impl true
  def get_car_data(params \\ %{}), do: Client.get_car_data(params)

  @impl true
  def get_intervals(params \\ %{}), do: Client.get_intervals(params)

  @impl true
  def get_team_radio(params \\ %{}), do: Client.get_team_radio(params)

  @impl true
  def get_weather(params \\ %{}), do: Client.get_weather(params)

  @impl true
  def get_stints(params \\ %{}), do: Client.get_stints(params)

  @impl true
  def get_meetings(params \\ %{}), do: Client.get_meetings(params)

  @impl true
  def get_location_range(session_key, from_iso, to_iso),
    do: Client.get_location_range(session_key, from_iso, to_iso)

  @impl true
  def get_location_for_driver(session_key, driver_number, from_iso, to_iso),
    do: Client.get_location_for_driver(session_key, driver_number, from_iso, to_iso)
end
