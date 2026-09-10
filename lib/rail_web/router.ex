defmodule RailWeb.Router do
  use RailWeb, :router

  alias RailWeb.Hooks.NavHook

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

  pipeline :require_admin_user do
    plug RailWeb.UserAuth, :require_authenticated_user
    plug RailWeb.UserAuth, :require_admin_user
  end

  pipeline :asset_session do
    plug :fetch_session
    plug :put_secure_browser_headers
    plug RailWeb.UserAuth, :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/webhooks", RailWeb do
    pipe_through :api

    post "/linear/:workspace_id", LinearWebhookController, :handle
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

    get "/settings", SettingsRedirectController, :index

    live_session :require_authenticated_user,
      layout: {RailWeb.Layouts, :app},
      root_layout: {RailWeb.Layouts, :root},
      on_mount: [
        {RailWeb.UserAuth, :require_authenticated},
        NavHook
      ] do
      live "/", OverviewLive
      live "/issues", IssuesLive
      live "/cli-accounts", CliAccountsLive
      live "/tasks/:id", TaskDetailLive
      live "/settings/connected-accounts", Settings.ConnectedAccountsLive
    end

    live_session :require_admin_user,
      layout: {RailWeb.Layouts, :app},
      root_layout: {RailWeb.Layouts, :root},
      on_mount: [
        {RailWeb.UserAuth, :require_authenticated},
        {RailWeb.UserAuth, :require_admin},
        NavHook
      ] do
      live "/settings/projects", Settings.ProjectsLive
      live "/settings/linear-workspace", Settings.LinearWorkspaceLive
    end
  end

  scope "/assets", RailWeb do
    pipe_through [:asset_session, :require_authenticated_user]

    get "/:kind/:id", AssetController, :show
  end

  scope "/", RailWeb do
    pipe_through :browser

    get "/_health", HealthController, :health
  end
end
