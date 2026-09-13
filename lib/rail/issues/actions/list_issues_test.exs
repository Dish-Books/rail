defmodule Rail.Issues.Actions.ListIssuesTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  setup do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "List Issues Project One",
        github_repo: "org/list-issues-one",
        github_installation_id: 5701,
        linear_workspace: %{
          name: "List Issues Workspace",
          external_id: "lin_ws_list_issues",
          token: "lin_api_token_list_issues",
          webhook_secret: "whsec_list_issues"
        },
        linear_team_key: "LI1",
        default_branch: "main",
        clone_path: "/tmp/repos/list-issues-one"
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, other_project} =
      Projects.create_project(system_scope(), %{
        name: "List Issues Project Two",
        github_repo: "org/list-issues-two",
        github_installation_id: 5702,
        linear_workspace: %{
          name: "List Issues Workspace Two",
          external_id: "lin_ws_list_issues_2",
          token: "lin_api_token_list_issues",
          webhook_secret: "whsec_list_issues"
        },
        linear_team_key: "LI2",
        default_branch: "main",
        clone_path: "/tmp/repos/list-issues-two"
      })

    %{project: project, other_project: other_project}
  end

  test "list_issues filters by project, state and whether finished issues show", %{
    project: %Project{id: project_id},
    other_project: other_project
  } do
    %Issue{id: triage_id} =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project_id,
        external_id: "lin_l1",
        identifier: "LI1-1",
        title: "Triage",
        state: :triage
      })
      |> Repo.insert!()

    %Issue{id: done_id} =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project_id,
        external_id: "lin_l2",
        identifier: "LI1-2",
        title: "Done",
        state: :done
      })
      |> Repo.insert!()

    %Issue{}
    |> Issue.changeset(%{
      project_id: other_project.id,
      external_id: "lin_l3",
      identifier: "LI2-1",
      title: "Elsewhere",
      state: :in_progress
    })
    |> Repo.insert!()

    assert %{issues: [%Issue{id: ^triage_id}], total: 1} = Issues.list_issues(project_id: project_id)

    assert %{issues: [%Issue{id: ^done_id}, %Issue{id: ^triage_id}], total: 2} =
             Issues.list_issues(project_id: project_id, show_finished: true)

    assert %{issues: [%Issue{id: ^triage_id}]} = Issues.list_issues(project_id: project_id, state: :triage)

    assert %{issues: [%Issue{id: ^triage_id, project: %Project{id: ^project_id}}]} =
             Issues.list_issues(project_id: project_id, preload: [:project])

    assert %{total: 3} = Issues.list_issues(show_finished: true)
    assert %{total: 2} = Issues.list_issues()
  end

  test "list_issues searches titles and identifiers, taking the search literally", %{project: project} do
    %Issue{id: login_id} =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_s1",
        identifier: "LI1-10",
        title: "Fix Login redirect",
        state: :triage
      })
      |> Repo.insert!()

    %Issue{id: percent_id} =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_s2",
        identifier: "LI1-20",
        title: "Show 100% width",
        state: :triage
      })
      |> Repo.insert!()

    %Issue{}
    |> Issue.changeset(%{
      project_id: project.id,
      external_id: "lin_s3",
      identifier: "LI1-30",
      title: "Other",
      state: :triage
    })
    |> Repo.insert!()

    assert %{issues: [%Issue{id: ^login_id}], total: 1} = Issues.list_issues(search: "login")
    assert %{issues: [%Issue{id: ^percent_id}]} = Issues.list_issues(search: "li1-20")
    assert %{issues: [%Issue{id: ^percent_id}]} = Issues.list_issues(search: "100%")
    assert %{issues: [], total: 0} = Issues.list_issues(search: "1_0")
    assert %{total: 3} = Issues.list_issues(search: "   ")
  end

  test "list_issues pages through issues, most recently updated first, and counts past the page", %{project: project} do
    issues =
      for {priority, n} <- Enum.with_index([:medium, :low, :high, :high, :urgent]) do
        %Issue{}
        |> Issue.changeset(%{
          project_id: project.id,
          external_id: "lin_p#{n}",
          identifier: "LI1-#{100 + n}",
          title: "Paged #{n}",
          priority: priority,
          state: :backlog
        })
        |> Repo.insert!()
      end

    [fifth, fourth, third, second, first] = Enum.map(issues, & &1.id)

    assert %{
             issues: [%Issue{id: ^first}, %Issue{id: ^second}],
             total: 5,
             priority_counts: %{urgent: 1, high: 2, low: 1, medium: 1}
           } = Issues.list_issues(limit: 2)

    assert %{issues: [%Issue{id: ^third}, %Issue{id: ^fourth}], total: 5} = Issues.list_issues(limit: 2, offset: 2)
    assert %{issues: [%Issue{id: ^fifth}]} = Issues.list_issues(limit: 2, offset: 4)

    # Picking a priority narrows the list and its total, but every chip still counts.
    assert %{
             issues: [%Issue{id: ^second}, %Issue{id: ^third}],
             total: 2,
             priority_counts: %{urgent: 1, high: 2, low: 1, medium: 1}
           } = Issues.list_issues(priority: :high)

    # Updating the oldest issue brings it to the top.
    issues |> List.first() |> Issue.changeset(%{title: "Touched"}) |> Repo.update!()
    assert %{issues: [%Issue{id: ^fifth}]} = Issues.list_issues(limit: 1)
  end

  test "list_issues preloads the issue's task", %{project: project} do
    issue =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_t1",
        identifier: "LI1-40",
        title: "Tasked",
        state: :backlog
      })
      |> Repo.insert!()

    {:ok, %Task{id: task_id}} = Pipeline.create_task(%{issue | project: project}, :product)

    assert %{issues: [%Issue{task: %Task{id: ^task_id, runs: []}}]} =
             Issues.list_issues(preload: [task: :runs])
  end

  test "list_issues narrows to the issues a user owns", %{project: project} do
    {:ok, %{id: owner_id}} =
      Rail.Users.register_oauth_user(%{github_id: "gh_list_owner", login: "list_owner", email: "list_owner@example.com"})

    %Issue{id: mine_id} =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_o1",
        identifier: "LI1-50",
        title: "Mine",
        state: :backlog,
        owner_user_id: owner_id
      })
      |> Repo.insert!()

    %Issue{}
    |> Issue.changeset(%{
      project_id: project.id,
      external_id: "lin_o2",
      identifier: "LI1-51",
      title: "Not mine",
      state: :backlog
    })
    |> Repo.insert!()

    assert %{issues: [%Issue{id: ^mine_id}], total: 1} = Issues.list_issues(owner_user_id: owner_id)
    assert %{total: 2} = Issues.list_issues()
  end
end
