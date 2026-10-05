defmodule Rail.Tools.Actions.ListBackendsTest do
  use Rail.DataCase, async: true

  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  test "list_backends/0 returns every configured backend" do
    %Backend{id: claude_id} =
      Repo.insert!(Backend.changeset(%Backend{}, %{name: :claude, executable_path: "/usr/bin/claude"}))

    %Backend{id: work_id} =
      Repo.insert!(Backend.changeset(%Backend{}, %{name: :claude, executable_path: "/usr/bin/claude", label: "work"}))

    # Alongside the one lib/test_helper.exs seeds for the shared project's roles.
    assert Tools.list_backends() |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort(["bkd_test_seed", claude_id, work_id])
  end
end
