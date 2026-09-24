defmodule Rail.Projects.Actions.CreateLinearWorkspaceTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Scope

  @attrs %{name: "Acme", external_id: "lin_org_create", token: "lin_api_create", webhook_secret: "whsec_create"}

  test "an admin creates a workspace" do
    assert {:ok, %LinearWorkspace{name: "Acme", external_id: "lin_org_create", token: "lin_api_create"}} =
             Projects.create_linear_workspace(Scope.for_user(%{admin: true}), @attrs)
  end

  test "a missing field is an error on it" do
    assert {:error, changeset} = Projects.create_linear_workspace(Scope.for_user(%{admin: true}), %{@attrs | token: ""})
    assert %{token: ["can't be blank"]} = errors_on(changeset)
  end

  test "rejects a non-admin" do
    assert {:error, :not_authorized} = Projects.create_linear_workspace(Scope.for_user(%{admin: false}), @attrs)
  end
end
