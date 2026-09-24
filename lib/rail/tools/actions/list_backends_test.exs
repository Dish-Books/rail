defmodule Rail.Tools.Actions.ListBackendsTest do
  use Rail.DataCase, async: true

  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  test "list_backends/0 returns every configured backend" do
    %Backend{id: claude_id} =
      Repo.insert!(Backend.changeset(%Backend{}, %{name: :claude, executable_path: "/usr/bin/claude"}))

    %Backend{id: agy_id} =
      Repo.insert!(Backend.changeset(%Backend{}, %{name: :agy, executable_path: "/usr/bin/agy"}))

    # Alongside the one lib/test_helper.exs seeds for the shared project's roles.
    assert Tools.list_backends() |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort(["bkd_test_seed", claude_id, agy_id])
  end
end
