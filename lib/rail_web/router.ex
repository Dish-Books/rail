defmodule RailWeb.Router do
  use RailWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug RailWeb.UserAuth, :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/auth", RailWeb do
    pipe_through :browser

    get "/logout", AuthController, :delete
    delete "/logout", AuthController, :delete
    get "/:provider", AuthController, :request
    get "/:provider/callback", AuthController, :callback
    post "/:provider/callback", AuthController, :callback
  end

  scope "/", RailWeb do
    pipe_through :browser

    get "/", HealthController, :health
    get "/_health", HealthController, :health
  end
end
