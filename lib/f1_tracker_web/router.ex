defmodule F1TrackerWeb.Router do
  use F1TrackerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {F1TrackerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", F1TrackerWeb do
    pipe_through :browser

    live "/", TrackerLive, :index
  end

  # Other scopes may use custom stacks.
  # scope "/api", F1TrackerWeb do
  #   pipe_through :api
  # end
end
