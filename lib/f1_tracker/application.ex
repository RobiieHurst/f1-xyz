defmodule F1Tracker.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      F1TrackerWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:f1_tracker, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: F1Tracker.PubSub},
      F1Tracker.OpenF1.TokenManager,
      F1Tracker.F1.SessionServer,
      F1Tracker.F1.ReplayServer,
      # Start to serve requests, typically the last entry
      F1TrackerWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: F1Tracker.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    F1TrackerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
