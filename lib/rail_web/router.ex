defmodule RailWeb.Router do
  use RailWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", RailWeb do
    pipe_through :browser

    get "/_health", HealthController, :health
  end
end
