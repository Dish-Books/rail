defmodule Rail.Projects.Schemas.LinearWorkspaceTest do
  use Rail.DataCase, async: true

  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Repo

  test "changeset validates required fields" do
    changeset = LinearWorkspace.changeset(%LinearWorkspace{}, %{})

    assert %{
             name: ["can't be blank"],
             external_id: ["can't be blank"],
             token: ["can't be blank"],
             webhook_secret: ["can't be blank"]
           } = errors_on(changeset)
  end

  test "changeset accepts valid attributes" do
    attrs = %{
      name: "Acme Linear",
      external_id: "lin_ws_test",
      token: "lin_api_test_key",
      webhook_secret: "whsec_test_secret"
    }

    changeset = LinearWorkspace.changeset(%LinearWorkspace{}, attrs)
    assert changeset.valid?
  end

  test "a blank secret keeps the one saved" do
    workspace = %LinearWorkspace{
      name: "Saved",
      external_id: "lin_ws_saved",
      token: "lin_api_saved",
      webhook_secret: "whsec_saved"
    }

    changeset = LinearWorkspace.changeset(workspace, %{"name" => "Renamed", "token" => "", "webhook_secret" => nil})

    assert changeset.valid?
    assert changeset.changes == %{name: "Renamed"}
  end

  test "changeset enforces uniqueness on external_id" do
    ext_id = "lin_ext_#{System.unique_integer([:positive])}"

    assert {:ok, %LinearWorkspace{external_id: ^ext_id}} =
             %LinearWorkspace{}
             |> LinearWorkspace.changeset(%{
               name: "Workspace 1",
               external_id: ext_id,
               token: "token_1",
               webhook_secret: "secret_1"
             })
             |> Repo.insert()

    assert {:error, changeset} =
             %LinearWorkspace{}
             |> LinearWorkspace.changeset(%{
               name: "Workspace 2",
               external_id: ext_id,
               token: "token_2",
               webhook_secret: "secret_2"
             })
             |> Repo.insert()

    assert %{external_id: ["has already been taken"]} = errors_on(changeset)
  end

  test "token and webhook_secret are redacted in inspect" do
    {:ok, workspace} =
      %LinearWorkspace{}
      |> LinearWorkspace.changeset(%{
        name: "Redacted Workspace",
        external_id: "lin_ext_#{System.unique_integer([:positive])}",
        token: "tok_redacted",
        webhook_secret: "whsec_redacted"
      })
      |> Repo.insert()

    inspected = inspect(workspace, limit: :infinity)

    refute String.contains?(inspected, workspace.token)
    refute String.contains?(inspected, workspace.webhook_secret)
  end
end
