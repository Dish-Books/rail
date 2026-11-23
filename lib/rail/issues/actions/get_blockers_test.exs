defmodule Rail.Issues.Actions.GetBlockersTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects

  setup do
    key = "Gbl#{System.unique_integer([:positive])}"

    {:ok, local} =
      Projects.create_project(system_scope(), %{
        name: "Blocked",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    %{local: local}
  end

  test "an issue's blockers and what it blocks come from its relations, each in the project", %{local: local} do
    {:ok, %Issue{id: issue_id} = issue} =
      Issues.create_issue(system_scope(), local, %{title: "In the middle"})

    {:ok, %Issue{id: first_id} = first} = Issues.create_issue(system_scope(), local, %{title: "Goes first"})

    {:ok, %Issue{id: later_id} = later} =
      Issues.create_issue(system_scope(), local, %{title: "Waits"})

    {:ok, %Issue{id: unrelated_id} = unrelated} =
      Issues.create_issue(system_scope(), local, %{title: "Unrelated"})

    :ok = Issues.block_issue(system_scope(), first, issue)
    :ok = Issues.block_issue(system_scope(), issue, later)

    assert %{
             ^issue_id => %{
               blocked_by: [%{issue: %Issue{id: ^first_id, title: "Goes first"}, in_project: true}],
               blocks: [%{issue: %Issue{id: ^later_id, title: "Waits"}, in_project: true}]
             },
             ^unrelated_id => %{blocked_by: [], blocks: []}
           } = Issues.get_blockers([%{issue | project: local}, %{unrelated | project: local}])

    assert %{^later_id => %{blocked_by: [%{issue: %Issue{id: ^issue_id}}], blocks: []}} =
             Issues.get_blockers([%{later | project: local}])
  end

  test "open blockers come before finished ones, and an issue asked for twice is read once", %{local: local} do
    {:ok, %Issue{id: issue_id} = issue} = Issues.create_issue(system_scope(), local, %{title: "Held"})
    {:ok, %Issue{id: finished_id} = finished} = Issues.create_issue(system_scope(), local, %{title: "Finished one"})
    {:ok, %Issue{id: open_id} = open} = Issues.create_issue(system_scope(), local, %{title: "Open one"})
    {:ok, _done} = Issues.set_issue_status(system_scope(), finished, %{id: "done", name: "Done", state: :done})

    :ok = Issues.block_issue(system_scope(), finished, issue)
    :ok = Issues.block_issue(system_scope(), open, issue)

    issue = %{issue | project: local}

    assert %{
             ^issue_id => %{
               blocked_by: [
                 %{issue: %Issue{id: ^open_id, state: :triage}, in_project: true},
                 %{issue: %Issue{id: ^finished_id, state: :done}, in_project: true}
               ],
               blocks: []
             }
           } = Issues.get_blockers([issue, issue])
  end
end
