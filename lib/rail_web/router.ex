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

  pipeline :require_authenticated_user do
    plug RailWeb.UserAuth, :require_authenticated_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/auth/linear", RailWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/", LinearAuthController, :request
    get "/callback", LinearAuthController, :callback
    get "/unlink", LinearAuthController, :unlink
    post "/unlink", LinearAuthController, :unlink
    delete "/unlink", LinearAuthController, :unlink
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
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      layout: false,
      root_layout: false,
      on_mount: [{RailWeb.UserAuth, :require_authenticated}] do
      live "/settings/connected-accounts", Settings.ConnectedAccountsLive
    end
  end

  scope "/", RailWeb do
    pipe_through :browser

    get "/", HealthController, :health
    get "/_health", HealthController, :health
  end
end
