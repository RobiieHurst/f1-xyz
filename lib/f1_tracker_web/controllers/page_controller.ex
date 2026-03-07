defmodule F1TrackerWeb.PageController do
  use F1TrackerWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
