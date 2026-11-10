defmodule RailWeb.Components.IssuePickerTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Users

  setup %{conn: conn} do
    key = "Pck#{System.unique_integer([:positive])}"

    {:ok, local} =
      Projects.create_project(system_scope(), %{
        name: "Rail-tracked",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        tracker: :local,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "gh_#{key}", login: "user_#{key}", email: "#{key}@example.com"})

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [local.id]})
    {:ok, issue} = Issues.create_issue(system_scope(), local, %{title: "On the page"})
    {:ok, round} = Issues.create_issue(system_scope(), local, %{title: "Rounds number themselves"})
    {:ok, triage} = Issues.create_issue(system_scope(), local, %{title: "Triage finds duplicates"})
    stub(Issues, :link_pull_request, fn _scope, _issue -> {:ok, nil} end)
    stub(Issues, :get_blockers, fn issues -> call_original(Issues, :get_blockers, [issues]) end)

    %{conn: log_in_user(conn, user), local: local, issue: issue, round: round, triage: triage}
  end

  test "searches the project's issues by title or identifier, finished ones included", %{
    conn: conn,
    issue: %Issue{id: issue_id},
    round: %Issue{id: round_id, identifier: round_identifier} = round,
    triage: %Issue{id: triage_id}
  } do
    {:ok, _round} = Issues.set_issue_status(system_scope(), round, %{name: "Done", state: :done})
    {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")
    picker = "#issue-blocked-by-picker-#{issue_id}"

    view |> element("#{picker}-trigger") |> render_click()
    assert has_element?(view, "#{picker}-trigger[aria-expanded='true']")
    assert has_element?(view, "#{picker}-issue-#{round_id}")
    assert has_element?(view, "#{picker}-issue-#{triage_id}")

    view |> form("#{picker}-search-form", %{q: "rounds"}) |> render_change()
    assert has_element?(view, "#{picker}-issue-#{round_id}")
    refute has_element?(view, "#{picker}-issue-#{triage_id}")

    view |> form("#{picker}-search-form", %{q: String.downcase(round_identifier)}) |> render_change()
    assert has_element?(view, "#{picker}-issue-#{round_id}")

    view |> form("#{picker}-search-form", %{q: "nothing like it"}) |> render_change()
    assert has_element?(view, "#{picker}-empty", "No matching issues")

    view |> element("#{picker}-trigger") |> render_click()
    refute has_element?(view, "#{picker}-menu")
  end

  test "Blocks makes the page's issue the blocker, and the menu closes on the pick", %{
    conn: conn,
    issue: %Issue{id: issue_id, external_id: external_id} = issue,
    local: local,
    triage: %Issue{id: triage_id}
  } do
    {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")
    picker = "#issue-blocks-picker-#{issue_id}"

    view |> element("#{picker}-trigger") |> render_click()
    view |> element("#{picker}-issue-#{triage_id}") |> render_click()

    refute has_element?(view, "#{picker}-menu")

    assert %{^external_id => %{blocks: [%{issue: %Issue{id: ^triage_id}}], blocked_by: []}} =
             Issues.get_blockers([%{issue | project: local}])
  end

  test "a pick the action refuses keeps the menu open with the reason", %{
    conn: conn,
    issue: %Issue{id: issue_id},
    triage: %Issue{id: triage_id, identifier: triage_identifier} = triage
  } do
    {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")
    picker = "#issue-blocked-by-picker-#{issue_id}"

    view |> element("#{picker}-trigger") |> render_click()
    Repo.delete!(triage)
    view |> element("#{picker}-issue-#{triage_id}") |> render_click()

    assert has_element?(view, "#{picker}-error", "#{triage_identifier} is no longer in this project.")
    assert has_element?(view, "#{picker}-menu")
  end

  test "an issue the menu does not show cannot be picked by a crafted event", %{
    conn: conn,
    local: local,
    issue: %Issue{id: issue_id}
  } do
    {:ok, %Issue{id: hidden_id}} = Issues.create_issue(system_scope(), local, %{title: "Not listed"})
    {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")
    picker = "#issue-blocked-by-picker-#{issue_id}"

    view |> element("#{picker}-trigger") |> render_click()
    view |> form("#{picker}-search-form", %{q: "rounds"}) |> render_change()
    view |> with_target(picker) |> render_click("pick", %{"issue_id" => hidden_id})

    assert has_element?(view, "#{picker}-menu")
    refute has_element?(view, "#issue-blocked-by")
  end

  test "an open menu drops an issue once it is related from another tab, and a click away closes it", %{
    conn: conn,
    issue: %Issue{id: issue_id} = issue,
    round: %Issue{id: round_id} = round
  } do
    {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")
    picker = "#issue-blocks-picker-#{issue_id}"

    view |> element("#{picker}-trigger") |> render_click()
    assert has_element?(view, "#{picker}-issue-#{round_id}")

    :ok = Issues.block_issue(system_scope(), round, issue)
    render_async(view)
    refute has_element?(view, "#{picker}-issue-#{round_id}")

    view |> with_target(picker) |> render_click("close", %{})
    refute has_element?(view, "#{picker}-menu")
  end

  test "No parent is refused with the reason when the issue is gone", %{conn: conn, issue: %Issue{id: issue_id} = issue} do
    {:ok, view, _html} = live(conn, ~p"/issues/#{issue_id}")
    picker = "#issue-parent-picker-#{issue_id}"

    view |> element("#issue-parent") |> render_click()
    Repo.delete!(issue)
    view |> element("#{picker}-none") |> render_click()

    assert has_element?(view, "#{picker}-error", "#{issue.identifier} is no longer in this project.")
  end
end
