defmodule F1Tracker.DataProvider do
  @moduledoc """
  Provider dispatcher for F1 data access.

  All runtime data fetches should go through this module so backend providers
  can be swapped without changing business logic.
  """

  @behaviour F1Tracker.DataProviders.Provider

  def provider_module do
    Application.get_env(:f1_tracker, :data_provider, F1Tracker.DataProviders.OpenF1)
  end

  @impl true
  def get_location(params \\ %{}), do: provider_module().get_location(params)

  @impl true
  def get_laps(params \\ %{}), do: provider_module().get_laps(params)

  @impl true
  def get_drivers(params \\ %{}), do: provider_module().get_drivers(params)

  @impl true
  def get_sessions(params \\ %{}), do: provider_module().get_sessions(params)

  @impl true
  def get_position(params \\ %{}), do: provider_module().get_position(params)

  @impl true
  def get_pit(params \\ %{}), do: provider_module().get_pit(params)

  @impl true
  def get_race_control(params \\ %{}), do: provider_module().get_race_control(params)

  @impl true
  def get_car_data(params \\ %{}), do: provider_module().get_car_data(params)

  @impl true
  def get_intervals(params \\ %{}), do: provider_module().get_intervals(params)

  @impl true
  def get_team_radio(params \\ %{}), do: provider_module().get_team_radio(params)

  @impl true
  def get_weather(params \\ %{}), do: provider_module().get_weather(params)

  @impl true
  def get_stints(params \\ %{}), do: provider_module().get_stints(params)

  @impl true
  def get_meetings(params \\ %{}), do: provider_module().get_meetings(params)

  @impl true
  def get_location_range(session_key, from_iso, to_iso),
    do: provider_module().get_location_range(session_key, from_iso, to_iso)

  @impl true
  def get_location_for_driver(session_key, driver_number, from_iso, to_iso),
    do: provider_module().get_location_for_driver(session_key, driver_number, from_iso, to_iso)
end
