defmodule Rail.Projects.Actions.UpsertLinearWorkspaceTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Scope

  test "creates a new singleton workspace when none exists" do
    admin_scope = Scope.for_user(%{admin: true})
    ext_id = "lin_ws_#{System.unique_integer([:positive])}"

    attrs = %{
      name: "Acme Linear",
      external_id: ext_id,
      token: "lin_api_tok_123",
      webhook_secret: "whsec_abc_456"
    }

    assert {:ok, %LinearWorkspace{name: "Acme Linear", external_id: ^ext_id}} =
             Projects.upsert_linear_workspace(admin_scope, attrs)
  end

  test "updates the existing singleton workspace when one already exists" do
    admin_scope = Scope.for_user(%{admin: true})
    ext_id = "lin_ws_#{System.unique_integer([:positive])}"

    attrs1 = %{
      name: "Old Workspace Name",
      external_id: ext_id,
      token: "token_v1",
      webhook_secret: "secret_v1"
    }

    assert {:ok, %LinearWorkspace{id: workspace_id}} =
             Projects.upsert_linear_workspace(admin_scope, attrs1)

    attrs2 = %{
      name: "New Workspace Name",
      external_id: ext_id,
      token: "token_v2",
      webhook_secret: "secret_v2"
    }

    assert {:ok, %LinearWorkspace{id: ^workspace_id, name: "New Workspace Name"}} =
             Projects.upsert_linear_workspace(admin_scope, attrs2)
  end

  test "returns validation error changeset for missing fields" do
    admin_scope = Scope.for_user(%{admin: true})

    assert {:error, changeset} = Projects.upsert_linear_workspace(admin_scope, %{})

    assert %{
             name: ["can't be blank"],
             external_id: ["can't be blank"],
             token: ["can't be blank"],
             webhook_secret: ["can't be blank"]
           } = errors_on(changeset)
  end

  test "rejects non-admin user scope" do
    user_scope = Scope.for_user(%{admin: false})

    attrs = %{
      name: "Unauthorized Workspace",
      external_id: "lin_ws_unauth",
      token: "token_unauth",
      webhook_secret: "secret_unauth"
    }

    assert {:error, :not_authorized} = Projects.upsert_linear_workspace(user_scope, attrs)
  end

  test "rejects nil scope" do
    attrs = %{
      name: "Nil Scope Workspace",
      external_id: "lin_ws_nil",
      token: "token_nil",
      webhook_secret: "secret_nil"
    }

    assert {:error, :not_authorized} = Projects.upsert_linear_workspace(nil, attrs)
  end
end
