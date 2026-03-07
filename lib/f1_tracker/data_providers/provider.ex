defmodule F1Tracker.DataProviders.Provider do
  @moduledoc """
  Behaviour for pluggable F1 data backends.

  Implementations should return `{:ok, data}` / `{:error, reason}` with payloads
  matching current OpenF1 shapes used by the application.
  """

  @callback get_location(map() | keyword()) :: {:ok, term()} | {:error, term()}
  @callback get_laps(map() | keyword()) :: {:ok, term()} | {:error, term()}
  @callback get_drivers(map() | keyword()) :: {:ok, term()} | {:error, term()}
  @callback get_sessions(map() | keyword()) :: {:ok, term()} | {:error, term()}
  @callback get_position(map() | keyword()) :: {:ok, term()} | {:error, term()}
  @callback get_pit(map() | keyword()) :: {:ok, term()} | {:error, term()}
  @callback get_race_control(map() | keyword()) :: {:ok, term()} | {:error, term()}
  @callback get_car_data(map() | keyword()) :: {:ok, term()} | {:error, term()}
  @callback get_intervals(map() | keyword()) :: {:ok, term()} | {:error, term()}
  @callback get_team_radio(map() | keyword()) :: {:ok, term()} | {:error, term()}
  @callback get_weather(map() | keyword()) :: {:ok, term()} | {:error, term()}
  @callback get_stints(map() | keyword()) :: {:ok, term()} | {:error, term()}
  @callback get_meetings(map() | keyword()) :: {:ok, term()} | {:error, term()}

  @callback get_location_range(session_key :: integer(), from_iso :: binary(), to_iso :: binary()) ::
              {:ok, term()} | {:error, term()}

  @callback get_location_for_driver(
              session_key :: integer(),
              driver_number :: integer(),
              from_iso :: binary(),
              to_iso :: binary()
            ) :: {:ok, term()} | {:error, term()}
end
