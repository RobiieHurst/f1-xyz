defmodule F1Tracker.OpenF1.TokenManager do
  @moduledoc """
  Manages OAuth2 access tokens for the OpenF1 API.

  Fetches a Bearer token using username/password credentials,
  caches it, and automatically refreshes before expiry.
  Operates as a no-op when credentials are not configured.
  """
  use GenServer
  require Logger

  @token_url "https://api.openf1.org/token"
  # Refresh 5 minutes before expiry to avoid race conditions
  @refresh_buffer_seconds 300

  # -- Public API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the current access token, or nil if not authenticated.
  """
  def get_token do
    GenServer.call(__MODULE__, :get_token)
  end

  @doc """
  Returns true if credentials are configured and a token is available.
  """
  def authenticated? do
    GenServer.call(__MODULE__, :authenticated?)
  end

  # -- Callbacks --

  @impl true
  def init(_opts) do
    config = Application.get_env(:f1_tracker, :openf1, [])
    username = config[:username]
    password = config[:password]

    state = %{
      username: username,
      password: password,
      access_token: nil,
      expires_at: nil,
      configured: username != nil and password != nil
    }

    if state.configured do
      # Fetch initial token asynchronously
      send(self(), :fetch_token)
      Logger.info("[TokenManager] OpenF1 credentials configured, fetching initial token")
    else
      Logger.info(
        "[TokenManager] No OpenF1 credentials configured, running in unauthenticated mode"
      )
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:get_token, _from, state) do
    {:reply, state.access_token, state}
  end

  @impl true
  def handle_call(:authenticated?, _from, state) do
    {:reply, state.configured and state.access_token != nil, state}
  end

  @impl true
  def handle_info(:fetch_token, %{configured: false} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:fetch_token, state) do
    case fetch_access_token(state.username, state.password) do
      {:ok, token, expires_in} ->
        expires_at = System.monotonic_time(:second) + expires_in
        refresh_in = max(expires_in - @refresh_buffer_seconds, 60)

        Logger.info(
          "[TokenManager] Token acquired, expires in #{expires_in}s, refreshing in #{refresh_in}s"
        )

        schedule_refresh(refresh_in)

        {:noreply, %{state | access_token: token, expires_at: expires_at}}

      {:error, reason} ->
        Logger.error("[TokenManager] Failed to fetch token: #{inspect(reason)}, retrying in 30s")
        schedule_refresh(30)

        {:noreply, state}
    end
  end

  # -- Private --

  defp fetch_access_token(username, password) do
    body = URI.encode_query(%{"username" => username, "password" => password})

    case Req.post(@token_url,
           body: body,
           headers: [{"content-type", "application/x-www-form-urlencoded"}]
         ) do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => token} = resp}} ->
        expires_in =
          case resp["expires_in"] do
            val when is_integer(val) -> val
            val when is_binary(val) -> String.to_integer(val)
            _ -> 3600
          end

        {:ok, token, expires_in}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp schedule_refresh(seconds) do
    Process.send_after(self(), :fetch_token, seconds * 1_000)
  end
end
