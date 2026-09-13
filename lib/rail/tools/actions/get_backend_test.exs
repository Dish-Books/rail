defmodule Rail.Tools.Actions.GetBackendTest do
  use Rail.DataCase, async: true

  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  test "get_backend/1 finds a backend by id" do
    %Backend{id: backend_id} =
      Repo.insert!(Backend.changeset(%Backend{}, %{name: :claude, executable_path: "/usr/bin/claude"}))

    assert {:ok, %Backend{id: ^backend_id}} = Tools.get_backend(backend_id)
    assert {:error, :backend_not_found} = Tools.get_backend("bkd_missing")
  end
end
