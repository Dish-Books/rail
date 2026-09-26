defmodule RailWeb.Router do
  use RailWeb, :router

  import Oban.Web.Router

  alias RailWeb.Hooks.NavHook

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :put_root_layout, html: {RailWeb.Layouts, :root}
    plug RailWeb.UserAuth, :fetch_current_user
  end

  pipeline :require_authenticated_user do
    plug RailWeb.UserAuth, :require_authenticated_user
  end

  pipeline :require_admin_user do
    plug RailWeb.UserAuth, :require_authenticated_user
    plug RailWeb.UserAuth, :require_admin_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :mcp do
    plug :accepts, ["json"]
    plug RailWeb.Plugs.McpRunAuth
  end

  scope "/webhooks", RailWeb do
    pipe_through :api

    post "/linear", LinearWebhookController, :handle
  end

  scope "/mcp", RailWeb do
    pipe_through :mcp

    post "/", McpController, :handle
    get "/", McpController, :stream
  end

  scope "/auth/linear", RailWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/", LinearAuthController, :request
    get "/callback", LinearAuthController, :callback
  end

  scope "/auth/slack", RailWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/", SlackAuthController, :request
    get "/callback", SlackAuthController, :callback
  end

  scope "/auth/mcp", RailWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/callback", McpAuthController, :callback
    get "/:server_id", McpAuthController, :request
  end

  scope "/", RailWeb do
    pipe_through :browser

    get "/sign-in", SignInController, :index
  end

  scope "/auth", RailWeb do
    pipe_through :browser

    get "/logout", AuthController, :delete
    delete "/logout", AuthController, :delete
    get "/denied", AuthController, :denied
    get "/:provider", AuthController, :request
    get "/:provider/callback", AuthController, :callback
    post "/:provider/callback", AuthController, :callback
  end

  scope "/", RailWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/settings", SettingsRedirectController, :index
    get "/project-selection", ProjectSelectionController, :select
    get "/issues/:issue_id/assets/*path", IssueAssetController, :show
    get "/tasks/:task_id/design/:key", DesignController, :show
    get "/tasks/:task_id/design/:key/screenshot", DesignController, :screenshot
    get "/tasks/:task_id/demo/video", DemoController, :video
    get "/tasks/:task_id/qa/evidence/:file", QaController, :shot
    get "/tasks/:task_id/qa/:key/evidence/:index", QaController, :evidence

    live_session :require_authenticated_user,
      on_mount: [
        {RailWeb.UserAuth, :require_authenticated},
        NavHook
      ] do
      live "/", OverviewLive
      live "/issues", IssuesLive
      live "/issues/:id", IssueLive
      live "/triage", TriageLive
      live "/triage/:id", TriageLive
      live "/tasks/:id", TaskLive
      live "/settings/connected-accounts", Settings.ConnectedAccountsLive
    end

    live_session :require_admin_user,
      on_mount: [
        {RailWeb.UserAuth, :require_authenticated},
        {RailWeb.UserAuth, :require_admin},
        NavHook
      ] do
      live "/settings/projects", Settings.ProjectsLive
      live "/settings/linear-workspaces", Settings.LinearWorkspacesLive
      live "/settings/slack-workspaces", Settings.SlackWorkspacesLive
      live "/settings/users", Settings.UsersLive
      live "/settings/roles", Settings.RolesLive
      live "/settings/backends", Settings.BackendsLive
      live "/settings/mcp-servers", Settings.McpServersLive
    end
  end

  scope "/" do
    pipe_through [:browser, :require_admin_user]

    oban_dashboard "/oban",
      on_mount: [
        {RailWeb.UserAuth, :require_authenticated},
        {RailWeb.UserAuth, :require_admin}
      ]
  end

  scope "/", RailWeb do
    pipe_through :browser

    get "/_health", HealthController, :health
  end

  if Application.compile_env(:rail, :dev_routes, false) do
    scope "/dev", RailWeb do
      pipe_through :browser

      get "/login", DevLoginController, :login
      get "/login/:email", DevLoginController, :login
    end
  end
end
