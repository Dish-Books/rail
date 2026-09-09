defmodule Rail.Projects.Actions.GetLinearWorkspaceTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Scope

  test "retrieves singleton workspace by scope" do
    admin_scope = Scope.for_user(%{admin: true})
    ext_id = "lin_ws_#{System.unique_integer([:positive])}"

    assert {:ok, %LinearWorkspace{id: workspace_id}} =
             Projects.upsert_linear_workspace(admin_scope, %{
               name: "Singleton WS",
               external_id: ext_id,
               token: "tok_sing",
               webhook_secret: "wh_sing"
             })

    user_scope = Scope.for_user(%{admin: false})

    assert {:ok, %LinearWorkspace{id: ^workspace_id, name: "Singleton WS"}} =
             Projects.get_linear_workspace(user_scope)
  end

  test "retrieves workspace by id" do
    admin_scope = Scope.for_user(%{admin: true})
    ext_id = "lin_ws_#{System.unique_integer([:positive])}"

    assert {:ok, %LinearWorkspace{id: workspace_id}} =
             Projects.upsert_linear_workspace(admin_scope, %{
               name: "ID WS",
               external_id: ext_id,
               token: "tok_id",
               webhook_secret: "wh_id"
             })

    assert {:ok, %LinearWorkspace{id: ^workspace_id, name: "ID WS"}} =
             Projects.get_linear_workspace(workspace_id)
  end

  test "returns {:error, :not_found} when no workspace exists" do
    user_scope = Scope.for_user(%{admin: false})
    assert {:error, :not_found} = Projects.get_linear_workspace(user_scope)
    assert {:error, :not_found} = Projects.get_linear_workspace("lw_000000000000000000000000")
  end

  test "get_linear_workspace! retrieves existing workspace" do
    admin_scope = Scope.for_user(%{admin: true})
    ext_id = "lin_ws_#{System.unique_integer([:positive])}"

    assert {:ok, %LinearWorkspace{id: workspace_id}} =
             Projects.upsert_linear_workspace(admin_scope, %{
               name: "Bang WS",
               external_id: ext_id,
               token: "tok_bang",
               webhook_secret: "wh_bang"
             })

    assert %LinearWorkspace{id: ^workspace_id, name: "Bang WS"} =
             Projects.get_linear_workspace!(admin_scope)

    assert %LinearWorkspace{id: ^workspace_id, name: "Bang WS"} =
             Projects.get_linear_workspace!(workspace_id)
  end

  test "get_linear_workspace! raises Ecto.NoResultsError when no workspace exists" do
    user_scope = Scope.for_user(%{admin: false})

    assert_raise Ecto.NoResultsError, fn ->
      Projects.get_linear_workspace!(user_scope)
    end

    assert_raise Ecto.NoResultsError, fn ->
      Projects.get_linear_workspace!("lw_000000000000000000000000")
    end
  end
end
