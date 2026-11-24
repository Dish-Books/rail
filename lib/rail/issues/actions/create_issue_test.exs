defmodule Rail.Issues.Actions.CreateIssueTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Cycle
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.AdvanceTrackerState
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Projects
  alias Rail.Users
  alias Rail.Workflows.Schemas.Workflow
  alias Rail.Workflows.Schemas.WorkflowDefinition

  # Each test makes its own project, since a shared one would hold the numbering lock across tests.
  setup do
    key = "Loc#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Numbered",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    %{project: project, key: key}
  end

  test "numbers each issue one past the last, and names and branches it from that number", %{
    project: %{id: project_id} = project,
    key: key
  } do
    branch_prefix = String.downcase(key)
    identifier_1 = "#{key}-1"
    identifier_2 = "#{key}-2"
    identifier_3 = "#{key}-3"
    branch_1 = "#{branch_prefix}-1-comments-left-on-diff-lines"
    branch_2 = "#{branch_prefix}-2-the-diff-pane-scrolls-past-its-end"
    branch_3 = "#{branch_prefix}-3"

    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    assert {:ok,
            %Issue{
              id: "iss_" <> _id = issue_id,
              project_id: ^project_id,
              number: 1,
              identifier: ^identifier_1,
              branch_name: ^branch_1,
              state: :todo,
              priority: :high,
              title: "Comments left on diff lines",
              description: "They vanish on reload"
            }} =
             Issues.create_issue(system_scope(), project, %{
               title: "Comments left on diff lines",
               description: "They vanish on reload",
               priority: :high
             })

    assert_receive {:issue_created, ^issue_id}

    assert {:ok, %Issue{number: 2, identifier: ^identifier_2, branch_name: ^branch_2}} =
             Issues.create_issue(system_scope(), project, %{title: "  The diff pane: scrolls past its end!  "})

    assert {:ok, %Issue{number: 3, identifier: ^identifier_3, branch_name: ^branch_3}} =
             Issues.create_issue(system_scope(), project, %{title: "!!!"})
  end

  test "numbers each project on its own", %{project: project, key: key} do
    other_key = "Oth#{System.unique_integer([:positive])}"
    other_identifier = "#{other_key}-1"

    {:ok, other} =
      Projects.create_project(system_scope(), %{
        name: "Another",
        github_repo: "example/#{other_key}",
        github_installation_id: 1,
        key: other_key,
        default_branch: "main",
        clone_path: "/tmp/#{other_key}"
      })

    identifier = "#{key}-2"
    {:ok, _first} = Issues.create_issue(system_scope(), project, %{title: "First"})

    assert {:ok, %Issue{number: 2, identifier: ^identifier}} =
             Issues.create_issue(system_scope(), project, %{title: "Second"})

    assert {:ok, %Issue{number: 1, identifier: ^other_identifier}} =
             Issues.create_issue(system_scope(), other, %{title: "Elsewhere"})
  end

  test "links an issue and its sub-issue to their own pages, with nothing sent anywhere and no job queued", %{
    project: project,
    key: key
  } do
    identifier = "#{key}-2"

    {:ok, %Issue{id: parent_id, url: parent_url} = parent} =
      Issues.create_issue(system_scope(), project, %{title: "Split me", priority: :high})

    assert parent_url == RailWeb.Endpoint.url() <> "/issues/" <> parent_id

    assert {:ok,
            %Issue{
              id: child_id,
              identifier: ^identifier,
              parent_id: ^parent_id,
              state: :todo,
              estimate: 3
            }} =
             Issues.create_issue(system_scope(), project, %{title: "A part", estimate: 3, parent: parent})

    child_url = RailWeb.Endpoint.url() <> "/issues/" <> child_id
    assert %Issue{url: ^child_url} = Repo.get!(Issue, child_id)
    refute_enqueued(worker: SyncIssue)
    refute_enqueued(worker: AdvanceTrackerState)
  end

  test "opens a sub-issue in Todo under its parent, in the cycle given, with its estimate and its owner assigned", %{
    project: project
  } do
    {:ok, %{id: owner_id}} =
      Users.register_oauth_user(%{github_id: "gh_sub_issue_owner", login: "sub_owner", email: "sub_owner@example.com"})

    {:ok, %Issue{id: parent_id} = parent} =
      Issues.create_issue(system_scope(), project, %{title: "The whole"})

    %Cycle{id: cycle_id} =
      Repo.insert!(%Cycle{project_id: project.id, starts_on: ~D[2026-11-24], ends_on: ~D[2026-12-07]})

    assert {:ok,
            %Issue{
              state: :todo,
              estimate: 3,
              owner_user_id: ^owner_id,
              cycle_id: ^cycle_id,
              parent_id: ^parent_id
            }} =
             Issues.create_issue(system_scope(), project, %{
               title: "A child",
               estimate: 3,
               owner_user_id: owner_id,
               parent: parent,
               cycle_id: cycle_id
             })
  end

  test "opens a ticket in the initiative given", %{project: project} do
    {:ok, %{id: initiative_id}} = Rail.Initiatives.create_initiative(system_scope(), project, %{name: "Credo"})

    assert {:ok, %Issue{id: id, initiative_id: ^initiative_id}} =
             Issues.create_issue(system_scope(), project, %{title: "Grouped", initiative_id: initiative_id})

    assert %Issue{initiative_id: ^initiative_id} = Repo.get!(Issue, id)
  end

  test "defaults to medium priority", %{project: project} do
    assert {:ok, %Issue{priority: :medium, state: :todo, description: nil}} =
             Issues.create_issue(system_scope(), project, %{title: "No priority"})
  end

  test "refuses a priority that is not one of the known ones", %{project: %{id: project_id} = project} do
    assert {:error, %Ecto.Changeset{} = changeset} =
             Issues.create_issue(system_scope(), project, %{title: "Bad priority", priority: "invalid_priority"})

    assert %{priority: ["is invalid"]} = errors_on(changeset)
    refute Repo.exists?(from(i in Issue, where: i.project_id == ^project_id))
  end

  test "refuses an estimate below 0 or a blank title", %{project: %{id: project_id} = project} do
    assert {:error, %Ecto.Changeset{} = changeset} =
             Issues.create_issue(system_scope(), project, %{title: "Negative", estimate: -5})

    assert %{estimate: ["must be greater than or equal to 0"]} = errors_on(changeset)

    assert {:error, %Ecto.Changeset{} = changeset} = Issues.create_issue(system_scope(), project, %{title: "  "})
    assert %{title: ["can't be blank"]} = errors_on(changeset)
    refute Repo.exists?(from(i in Issue, where: i.project_id == ^project_id))
  end

  test "keeps the workflow opening it and the steps it skips", %{project: project} do
    %Workflow{id: workflow_id} =
      Repo.insert!(%Workflow{
        project_id: project.id,
        path: ".rail/workflows/sweep.yml",
        definition: %WorkflowDefinition{name: "Sweep", schedule: "0 9 * * 1", instructions: "Sweep the flaky tests."},
        next_run_at: ~U[2026-10-12 09:00:00Z]
      })

    assert {:ok, %Issue{id: id, workflow_id: ^workflow_id, skipped_steps: [:product, :demo]}} =
             Issues.create_issue(system_scope(), project, %{
               title: "Sweep 2026-10-12",
               workflow_id: workflow_id,
               skipped_steps: [:product, :demo]
             })

    assert %Issue{workflow_id: ^workflow_id, skipped_steps: [:product, :demo]} = Repo.get!(Issue, id)
  end

  test "two issues can never share a number", %{project: project} do
    {:ok, %Issue{number: 1}} = Issues.create_issue(system_scope(), project, %{title: "First"})

    assert {:error, changeset} =
             %Issue{}
             |> Issue.tracker_changeset(%{
               project_id: project.id,
               identifier: "taken",
               number: 1,
               title: "Same number",
               state: :todo
             })
             |> Repo.insert()

    assert %{number: ["has already been taken"]} = errors_on(changeset)
  end

  test "an issue inserted with an identifier of its own keeps it", %{project: project} do
    assert %Issue{identifier: "OLD-7"} =
             %Issue{}
             |> Issue.tracker_changeset(%{
               project_id: project.id,
               identifier: "OLD-7",
               title: "Named already",
               state: :todo
             })
             |> Repo.insert!()
  end

  test "only an insert goes without an identifier", %{project: project} do
    assert %Ecto.Changeset{valid?: true} =
             Issue.changeset(%Issue{}, %{project_id: project.id, title: "t", state: :todo})

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Named"})
    assert %{identifier: ["can't be blank"]} = issue |> Issue.changeset(%{identifier: nil}) |> errors_on()
  end
end
