defmodule RailWeb.Settings.WorkflowsLiveTest do
  use RailWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.IssueStage
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Users
  alias Rail.Workflows.Schemas.Workflow
  alias Rail.Workflows.Schemas.WorkflowDefinition

  setup %{conn: conn} do
    id = System.unique_integer([:positive])

    {:ok, admin} =
      Users.register_oauth_user(%{
        github_id: "wfl_admin_gh_#{id}",
        login: "wfl_admin_#{id}",
        email: "wfl_admin_#{id}@example.com",
        admin: true
      })

    {:ok, regular} =
      Users.register_oauth_user(%{github_id: "wfl_gh_#{id}", login: "wfl_#{id}", email: "wfl_#{id}@example.com"})

    %{conn: log_in_user(conn, admin), regular_conn: log_in_user(conn, regular)}
  end

  test "lists a merged workflow with its project, file, schedule and next start, and offers no way to edit it", %{
    conn: conn,
    project: project
  } do
    %Workflow{id: id} =
      Repo.insert!(%Workflow{
        project_id: project.id,
        path: ".rail/workflows/dependency-updates.yml",
        definition: %WorkflowDefinition{
          name: "Dependency updates",
          schedule: "0 9 * * 1",
          instructions: "Update the dependencies."
        },
        next_run_at: ~U[2026-10-12 09:00:00Z]
      })

    assert {:ok, view, _html} = live(conn, ~p"/settings/workflows")

    assert has_element?(view, "#tab-workflows")
    assert has_element?(view, "#workflows-list-section h2", "Workflows · 1")
    assert has_element?(view, "span#workflow-name-#{id}", "Dependency updates")
    assert has_element?(view, "#workflow-row-#{id} [data-qa=project-badge]", "TST")

    assert has_element?(
             view,
             ~s(a#workflow-file-#{id}[href="https://github.com/example/test-seed/blob/main/.rail/workflows/dependency-updates.yml"]),
             ".rail/workflows/dependency-updates.yml"
           )

    assert has_element?(view, ~s(#workflow-schedule-#{id}[title="0 9 * * 1"]), "Mondays at 09:00")
    assert has_element?(view, "#workflow-next-#{id}", "Next Mon Oct 12, 09:00")
    assert has_element?(view, "#workflow-state-#{id}", "On")

    refute has_element?(view, "#workflow-row-#{id}[phx-click]")
    refute has_element?(view, "#workflows-settings form")
    refute has_element?(view, "#workflows-settings textarea")
  end

  test "each workflow lists its stage sequence and what it skips", %{conn: conn, project: project} do
    definition = %WorkflowDefinition{name: "Sweep", schedule: "0 6 * * *", instructions: "Sweep."}

    %Workflow{id: some_off} =
      Repo.insert!(%Workflow{
        project_id: project.id,
        path: ".rail/workflows/dependency-updates.yml",
        definition: %{definition | skip: [:product, :design]},
        next_run_at: ~U[2026-10-12 06:00:00Z]
      })

    %Workflow{id: plan_off} =
      Repo.insert!(%Workflow{
        project_id: project.id,
        path: ".rail/workflows/flaky-test-sweep.yml",
        definition: %{definition | skip: [:product, :design, :architect, :demo]},
        next_run_at: ~U[2026-10-12 06:00:00Z]
      })

    %Workflow{id: none_off} =
      Repo.insert!(%Workflow{
        project_id: project.id,
        path: ".rail/workflows/a11y-audit.yml",
        definition: definition,
        next_run_at: ~U[2026-10-12 06:00:00Z]
      })

    stages = [
      %IssueStage{stage: :plan},
      %IssueStage{stage: :engineer},
      %IssueStage{stage: :custom, name: "License check", prompt: "Check each license."},
      %IssueStage{stage: :review}
    ]

    %Workflow{id: licensed} =
      Repo.insert!(%Workflow{
        project_id: project.id,
        path: ".rail/workflows/licensed.yml",
        definition: %{definition | stages: stages},
        next_run_at: ~U[2026-10-12 06:00:00Z]
      })

    assert {:ok, view, _html} = live(conn, ~p"/settings/workflows")

    assert view |> element("#workflow-stages-#{licensed}-stages") |> render() |> Floki.parse_fragment!() |> Floki.text() ==
             "Plan › Implement › License check › Review"

    assert has_element?(view, "#workflows-stages-header", "Stages")
    assert has_element?(view, "#workflow-stages-#{some_off}-stages", "Plan › Implement › Review")
    assert has_element?(view, "#workflow-stages-#{some_off}-skips", "Skips product and design")
    assert has_element?(view, "#workflow-stages-#{plan_off}-stages", "Implement › Review")
    assert has_element?(view, "#workflow-stages-#{plan_off}-skips", "Skips plan and demo")
    assert has_element?(view, "#workflow-stages-#{none_off}-stages", "Plan › Implement › Review")
    refute has_element?(view, "#workflow-stages-#{none_off}-skips")
  end

  test "a file path with a space links to the file", %{conn: conn, project: project} do
    %Workflow{id: id} =
      Repo.insert!(%Workflow{
        project_id: project.id,
        path: ".rail/workflows/with space.yml",
        definition: %WorkflowDefinition{
          name: "Dependency updates",
          schedule: "0 9 * * 1",
          instructions: "Update the dependencies."
        },
        next_run_at: ~U[2026-10-12 09:00:00Z]
      })

    assert {:ok, view, _html} = live(conn, ~p"/settings/workflows")

    assert has_element?(
             view,
             ~s(a#workflow-file-#{id}[href="https://github.com/example/test-seed/blob/main/.rail/workflows/with%20space.yml"])
           )
  end

  test "an invalid file reads Invalid, with no Run now or switch", %{conn: conn, project: project} do
    %Workflow{id: id} = Repo.insert!(%Workflow{project_id: project.id, path: ".rail/workflows/nightly-e2e.yml"})

    assert {:ok, view, _html} = live(conn, ~p"/settings/workflows")

    assert has_element?(view, "#workflow-name-#{id}", "nightly-e2e.yml")
    assert has_element?(view, ~s(td[colspan="2"] #workflow-invalid-#{id}), "Invalid")
    refute has_element?(view, "#workflow-schedule-#{id}")
    refute has_element?(view, "#workflow-stages-#{id}")
    refute has_element?(view, "#run-now-#{id}")
    refute has_element?(view, "#workflow-switch-#{id}")
  end

  test "the switch pauses a workflow and turns it back on", %{conn: conn, project: project} do
    %Workflow{id: id} =
      Repo.insert!(%Workflow{
        project_id: project.id,
        path: ".rail/workflows/dependency-updates.yml",
        definition: %WorkflowDefinition{
          name: "Dependency updates",
          schedule: "0 9 * * 1",
          instructions: "Update the dependencies."
        },
        next_run_at: ~U[2026-10-12 09:00:00Z]
      })

    {:ok, view, _html} = live(conn, ~p"/settings/workflows")

    view |> element("#workflow-switch-#{id}") |> render_click()

    assert has_element?(view, "#workflow-state-#{id}", "Paused")
    assert has_element?(view, "#workflow-next-#{id}", "None while paused")
    refute has_element?(view, "#workflow-switch-#{id}[checked]")
    assert %Workflow{paused: true} = Repo.get!(Workflow, id)

    view |> element("#workflow-switch-#{id}") |> render_click()

    assert has_element?(view, "#workflow-state-#{id}", "On")
    assert has_element?(view, "#workflow-next-#{id}", "Next Mon Oct 12, 09:00")
    assert %Workflow{paused: false} = Repo.get!(Workflow, id)
  end

  test "a switch clicked in a tab that missed another's pause sets the state it showed", %{conn: conn, project: project} do
    %Workflow{id: id} =
      Repo.insert!(%Workflow{
        project_id: project.id,
        path: ".rail/workflows/dependency-updates.yml",
        definition: %WorkflowDefinition{
          name: "Dependency updates",
          schedule: "0 9 * * 1",
          instructions: "Update the dependencies."
        },
        next_run_at: ~U[2026-10-12 09:00:00Z]
      })

    {:ok, first, _html} = live(conn, ~p"/settings/workflows")
    {:ok, second, _html} = live(conn, ~p"/settings/workflows")

    first |> element("#workflow-switch-#{id}") |> render_click()
    assert has_element?(second, "#workflow-state-#{id}", "Paused")

    # A click sent from the second tab before it heard asks for the pause it already has.
    render_click(second, "set_paused", %{"id" => id, "paused" => "true"})
    assert %Workflow{paused: true} = Repo.get!(Workflow, id)
  end

  test "Run now on a paused workflow opens one issue, and a second press says why it opened nothing", %{
    conn: conn,
    project: project
  } do
    %Workflow{id: id} =
      Repo.insert!(%Workflow{
        project_id: project.id,
        path: ".rail/workflows/dependency-updates.yml",
        definition: %WorkflowDefinition{
          name: "Dependency updates",
          schedule: "0 9 * * 1",
          instructions: "Update the dependencies."
        },
        next_run_at: ~U[2026-10-12 09:00:00Z]
      })

    {:ok, view, _html} = live(conn, ~p"/settings/workflows")
    view |> element("#workflow-switch-#{id}") |> render_click()

    stub(DateTime, :utc_now, fn -> ~U[2026-10-14 10:00:00.000000Z] end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_TST-84", "identifier" => "TST-84", "title" => "Dependency updates 2026-10-14"}
          }
        }
      })
    end)

    assert view |> element("#run-now-#{id}") |> render_click() =~ "Dependency updates opened TST-84."
    assert [%Issue{title: "Dependency updates 2026-10-14"}] = Repo.all(from(i in Issue, where: i.workflow_id == ^id))
    assert has_element?(view, "#workflow-next-#{id}", "None while paused")

    # Jobs do not run here, so the issue still has no task.
    assert view |> element("#run-now-#{id}") |> render_click() =~
             "Dependency updates opened nothing: TST-84 is still unfinished and has no task yet. " <>
               "You can start it from its page."

    assert [_one] = Repo.all(from(i in Issue, where: i.workflow_id == ^id))
  end

  test "Run now on a workflow whose unfinished issue has a task says only that it is unfinished", %{
    conn: conn,
    project: project
  } do
    %Workflow{id: id} =
      Repo.insert!(%Workflow{
        project_id: project.id,
        path: ".rail/workflows/dependency-updates.yml",
        definition: %WorkflowDefinition{
          name: "Dependency updates",
          schedule: "0 9 * * 1",
          instructions: "Update the dependencies."
        },
        next_run_at: ~U[2026-10-12 09:00:00Z]
      })

    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        workflow_id: id,
        external_id: "lin_TST-84",
        identifier: "TST-84",
        title: "Dependency updates 2026-10-12",
        state: :in_progress
      })
      |> Repo.insert!()

    {:ok, %Task{}} = issue |> Repo.preload(:project) |> Pipeline.create_task(:plan)
    {:ok, view, _html} = live(conn, ~p"/settings/workflows")

    assert view |> element("#run-now-#{id}") |> render_click() =~
             "Dependency updates opened nothing: TST-84 is still unfinished."

    refute render(view) =~ "has no task yet"
  end

  test "a workflow on an inactive project has no next start, and Run now says why it opened nothing", %{conn: conn} do
    {:ok, inactive} =
      Projects.create_project(system_scope(), %{
        name: "Ledger",
        github_repo: "example/ledger",
        github_installation_id: 1,
        default_branch: "main",
        key: "LED",
        clone_path: "/tmp/repos/ledger",
        active: false
      })

    %Workflow{id: id} =
      Repo.insert!(%Workflow{
        project_id: inactive.id,
        path: ".rail/workflows/changelog.yml",
        definition: %WorkflowDefinition{
          name: "Changelog draft",
          schedule: "0 9 * * 1",
          instructions: "Update the dependencies."
        },
        next_run_at: ~U[2026-10-12 09:00:00Z]
      })

    {:ok, view, _html} = live(conn, ~p"/settings/workflows")

    assert has_element?(view, "#workflow-next-#{id}", "None while the project is inactive")
    assert view |> element("#run-now-#{id}") |> render_click() =~ "Changelog draft opened nothing: LED is inactive."

    {:ok, _active} = Projects.update_project(system_scope(), inactive, %{active: true})
    assert has_element?(view, "#workflow-next-#{id}", "Next Mon Oct 12, 09:00")
  end

  test "Run now from a page that missed its file turning invalid says so", %{conn: conn, project: project} do
    %Workflow{id: id} =
      Repo.insert!(%Workflow{
        project_id: project.id,
        path: ".rail/workflows/dependency-updates.yml",
        definition: %WorkflowDefinition{
          name: "Dependency updates",
          schedule: "0 9 * * 1",
          instructions: "Update the dependencies."
        },
        next_run_at: ~U[2026-10-12 09:00:00Z]
      })

    {:ok, view, _html} = live(conn, ~p"/settings/workflows")

    # Written behind the page's back, so it still offers Run now.
    Repo.update_all(from(w in Workflow, where: w.id == ^id), set: [definition: nil, next_run_at: nil])

    assert view |> element("#run-now-#{id}") |> render_click() =~
             "Dependency updates opened nothing: its file is invalid."
  end

  test "Run now says what the tracker answered when it opened nothing", %{conn: conn, project: project} do
    %Workflow{id: id} =
      Repo.insert!(%Workflow{
        project_id: project.id,
        path: ".rail/workflows/dependency-updates.yml",
        definition: %WorkflowDefinition{
          name: "Dependency updates",
          schedule: "0 9 * * 1",
          instructions: "Update the dependencies."
        },
        next_run_at: ~U[2026-10-12 09:00:00Z]
      })

    {:ok, view, _html} = live(conn, ~p"/settings/workflows")
    Req.Test.expect(Rail.Linear, fn conn -> conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{}) end)

    assert view |> element("#run-now-#{id}") |> render_click() =~
             "Dependency updates opened nothing: {:linear_api_error, 500"
  end

  test "a sync shows on the open page without a reload", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/settings/workflows")
    assert has_element?(view, "#workflows-empty")

    %Workflow{id: id} =
      Repo.insert!(%Workflow{
        project_id: project.id,
        path: ".rail/workflows/dependency-updates.yml",
        definition: %WorkflowDefinition{
          name: "Dependency updates",
          schedule: "0 9 * * 1",
          instructions: "Update the dependencies."
        },
        next_run_at: ~U[2026-10-12 09:00:00Z]
      })

    Phoenix.PubSub.broadcast(Rail.PubSub, "workflows", {:workflows_changed, project.id})

    assert has_element?(view, "#workflow-name-#{id}", "Dependency updates")
    refute has_element?(view, "#workflows-empty")
  end

  test "with no workflow files it shows a commented example to copy", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/workflows")

    assert has_element?(view, "#workflows-empty", "No workflows yet.")
    assert has_element?(view, "#workflow-example", "# cron, in UTC: Mondays at 09:00")
    assert has_element?(view, "#workflow-example", "# the issue's description")
    assert has_element?(view, "#workflow-example", "skip: [product, design]")
    assert has_element?(view, "#workflow-example", "# any of product, design, architect, demo")
    assert has_element?(view, "#workflow-example", "# a custom stage, anywhere before review")
    assert has_element?(view, "#workflow-example", "Check each changed dependency against LICENSES.md.")
    assert has_element?(view, ~s(#copy-workflow-example[phx-hook="CopyText"][data-copy-text*="name: Dependency updates"]))
    refute has_element?(view, "#workflows-list")
  end

  test "someone who is not an admin is sent away and has no Workflows tab", %{regular_conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings/workflows")

    {:ok, view, _html} = live(conn, ~p"/settings/connected-accounts")
    refute has_element?(view, "#tab-workflows")
  end
end
