defmodule Rail.Issues.Utils.TokenResolverTest do
  use Rail.DataCase, async: true

  import ExUnit.CaptureLog
  import Rail.Issues.Utils.TokenResolver

  alias Rail.Projects
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Scope
  alias Rail.Users

  test "resolve_token/2 resolves user token when user has linked token" do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_token_user",
        login: "token_user",
        email: "token_user@example.com"
      })

    {:ok, user} =
      Users.update_user(Scope.for_system(), user, %{
        linear_access_token: "lin_user_tok_1",
        linear_refresh_token: "lin_user_refresh_1",
        linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
      })

    scope = Scope.for_user(user)

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Token Resolver Project",
        github_repo: "org/token-resolver",
        github_installation_id: 5301,
        linear_team_id: "team_token_resolver",
        linear_team_key: "TKR",
        default_branch: "main",
        clone_path: "/tmp/repos/token-resolver"
      })

    assert {:ok, "lin_user_tok_1", :user} = resolve_token(scope, project)
  end

  test "resolve_token/2 falls back to workspace token and warns when user not linked" do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Token Resolver Fallback Project",
        github_repo: "org/token-resolver-fallback",
        github_installation_id: 5302,
        linear_workspace: %{
          name: "Token Resolver Workspace",
          external_id: "lin_ws_token_resolver",
          token: "lin_ws_tok_1",
          webhook_secret: "whsec_token_resolver"
        },
        linear_team_id: "team_token_resolver_fallback",
        linear_team_key: "TKF",
        default_branch: "main",
        clone_path: "/tmp/repos/token-resolver-fallback"
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_unlinked_user",
        login: "unlinked_user",
        email: "unlinked_user@example.com"
      })

    scope = Scope.for_user(user)

    log =
      capture_log(fn ->
        assert {:ok, "lin_ws_tok_1", :workspace} = resolve_token(scope, project)
      end)

    assert log =~ "[rail] pushed to Linear as the workspace"
  end

  test "resolve_token/2 returns error when user unlinked and no workspace token exists" do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Token Resolver No Workspace",
        github_repo: "org/token-resolver-none",
        github_installation_id: 5303,
        linear_team_id: "team_token_resolver_none",
        linear_team_key: "TKN",
        default_branch: "main",
        clone_path: "/tmp/repos/token-resolver-none"
      })

    log =
      capture_log(fn ->
        assert {:error, :no_workspace_token} = resolve_token(nil, project)
      end)

    refute log =~ "pushed to Linear as the workspace for project #{project.id}"
  end

  test "workspace_token/1 with LinearWorkspace directly" do
    workspace = %LinearWorkspace{token: "ws_direct_token"}
    assert {:ok, "ws_direct_token"} = workspace_token(workspace)
  end

  test "workspace_token/1 with preloaded Project.linear_workspace" do
    workspace = %LinearWorkspace{token: "preloaded_tok"}
    project = %Project{linear_workspace: workspace}
    assert {:ok, "preloaded_tok"} = workspace_token(project)
  end

  test "workspace_token/1 returns error when the project has no workspace" do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Token Resolver Missing Workspace",
        github_repo: "org/token-resolver-missing",
        github_installation_id: 5304,
        linear_team_id: "team_token_resolver_missing",
        linear_team_key: "TKM",
        default_branch: "main",
        clone_path: "/tmp/repos/token-resolver-missing"
      })

    assert {:error, :no_workspace_token} = workspace_token(%{project | linear_workspace: nil})
  end

  test "workspace_token/1 returns error for anything else" do
    assert {:error, :no_workspace_token} = workspace_token(nil)
  end
end
