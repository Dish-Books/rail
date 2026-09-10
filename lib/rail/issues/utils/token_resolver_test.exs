defmodule Rail.Issues.Utils.TokenResolverTest do
  use Rail.DataCase, async: true

  import ExUnit.CaptureLog
  import Rail.Issues.Utils.TokenResolver

  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  test "resolve_token/2 resolves user token when user has linked token" do
    user =
      Repo.insert!(%{
        User.factory()
        | linear_access_token: "lin_user_tok_1",
          linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
      })

    scope = Scope.for_user(user)
    project = Repo.insert!(Project.factory())

    assert {:ok, "lin_user_tok_1", :user} = resolve_token(scope, project)
  end

  test "resolve_token/2 falls back to workspace token and warns when user not linked" do
    workspace = Repo.insert!(%{LinearWorkspace.factory() | token: "lin_ws_tok_1"})
    project = Repo.insert!(%{Project.factory() | linear_workspace_id: workspace.id})
    user = Repo.insert!(%{User.factory() | linear_access_token: nil})
    scope = Scope.for_user(user)

    log =
      capture_log(fn ->
        assert {:ok, "lin_ws_tok_1", :workspace} = resolve_token(scope, project)
      end)

    assert log =~ "[rail] pushed to Linear as the workspace"
  end

  test "resolve_token/2 returns error when user unlinked and no workspace token exists" do
    project = Repo.insert!(%{Project.factory() | linear_workspace_id: nil})

    log =
      capture_log(fn ->
        assert {:error, :no_workspace_token} = resolve_token(nil, project)
      end)

    assert log == ""
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

  test "workspace_token/1 returns error when workspace token is empty" do
    workspace = Repo.insert!(%{LinearWorkspace.factory() | token: ""})
    project = Repo.insert!(%{Project.factory() | linear_workspace_id: workspace.id})

    assert {:error, :no_workspace_token} = workspace_token(project)
  end

  test "workspace_token/1 fallback queries default workspace from DB" do
    workspace = Repo.insert!(%{LinearWorkspace.factory() | token: "db_first_tok"})
    assert {:ok, "db_first_tok"} = workspace_token(nil)

    Repo.delete!(workspace)
    assert {:error, :no_workspace_token} = workspace_token(nil)
  end
end
