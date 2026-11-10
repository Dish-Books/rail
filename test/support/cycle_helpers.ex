defmodule RailTest.CycleHelpers do
  @moduledoc """
  Arranges Rail-tracked projects and their cycles through the contexts' public APIs.
  """

  import Mimic

  alias Rail.Issues
  alias Rail.Projects
  alias Rail.Scope

  @doc "An active project that keeps its tickets in Rail, under a key no other test holds."
  def local_project(attrs \\ %{}) do
    key = "Loc#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(
        Scope.for_system(),
        Map.merge(
          %{
            name: "Rail-tracked",
            github_repo: "example/#{key}",
            github_installation_id: 1,
            tracker: :local,
            key: key,
            default_branch: "main",
            clone_path: "/tmp/#{key}"
          },
          attrs
        )
      )

    project
  end

  @doc """
  Cycle 1 of `project` runs Nov 10 to 23, 2026, holding `rolled`, started, and `kept`, finished, when it closes. Then on
  Nov 25 `rolled` is finished in Cycle 2 and `kept` reopened. Leaves `Date.utc_today/0` at Nov 25.
  """
  def rolled_over_cycle(project) do
    scope = Scope.for_system()
    :ok = Issues.close_cycle_day(~D[2026-11-10])
    stub(Date, :utc_today, fn -> ~D[2026-11-12] end)
    {:ok, %{cycles: [first, second | _later]}} = Issues.get_cycles(project)
    {:ok, rolled} = Issues.create_issue(scope, project, %{title: "Rolls over", estimate: 3})
    {:ok, kept} = Issues.create_issue(scope, project, %{title: "Stays", estimate: 2})
    {:ok, rolled} = Issues.set_issue_cycle(scope, rolled, first.id)
    {:ok, kept} = Issues.set_issue_cycle(scope, kept, first.id)
    {:ok, rolled} = Issues.set_issue_status(scope, rolled, %{id: "in_progress", name: "In Progress", state: :in_progress})
    {:ok, kept} = Issues.set_issue_status(scope, kept, %{id: "done", name: "Done", state: :done})
    :ok = Issues.close_cycle_day(~D[2026-11-24])

    stub(Date, :utc_today, fn -> ~D[2026-11-25] end)
    {:ok, _done} = Issues.set_issue_status(scope, rolled, %{id: "done", name: "Done", state: :done})
    {:ok, _reopened} = Issues.set_issue_status(scope, kept, %{id: "todo", name: "Todo", state: :todo})

    %{first: first, second: second, rolled: rolled, kept: kept}
  end
end
