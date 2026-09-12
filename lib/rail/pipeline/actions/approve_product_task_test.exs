defmodule Rail.Pipeline.Actions.ApproveProductTaskTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(scope, %{
        name: "Approve Product Workspace",
        external_id: "lin_ws_approve_product",
        token: "lin_api_token_approve_product",
        webhook_secret: "whsec_approve_product"
      })

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Approve Product Project 7101",
        github_repo: "org/approve-product-7101",
        github_installation_id: 7101,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_approve_product_7101",
        linear_team_key: "P7101",
        default_branch: "main",
        clone_path: create_temp_git_repo(),
        linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
      })

    for stage <- [:product, :design] do
      {:ok, _role} =
        Roles.create_role(scope, project, %{
          backend_id: backend.id,
          stage: stage,
          name: "#{stage} role",
          model: "claude-3-7-sonnet",
          system_prompt: "You are the #{stage} agent."
        })
    end

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_approve_product_1",
      "identifier" => "APT-1",
      "title" => "Attachments follow their source document"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Attachments follow their source document")

    scratch_dir = Path.join(System.tmp_dir!(), "rail_scratch_#{System.unique_integer([:positive])}")
    tickets_dir = Path.join(scratch_dir, "tickets")
    File.mkdir_p!(tickets_dir)
    on_exit(fn -> File.rm_rf(scratch_dir) end)

    name = "apt-#{System.unique_integer([:positive])}"

    task_attrs = %{
      issue_id: issue.id,
      title: issue.title,
      description: issue.description,
      stage: :product,
      stage_state: :awaiting_approval,
      worktree_name: name,
      worktree_path: Path.join(project.clone_path, ".worktrees/#{name}"),
      scratch_path: scratch_dir
    }

    task =
      %Task{}
      |> Task.changeset(task_attrs, project.id)
      |> Repo.insert!()

    %{
      scope: scope,
      project: project,
      issue: issue,
      task: task,
      task_attrs: task_attrs,
      tickets_dir: tickets_dir
    }
  end

  test "publishes the ticket, adopts it, and starts the design run", %{
    task: %Task{id: task_id} = task,
    issue: issue,
    tickets_dir: tickets_dir
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    File.write!(Path.join(tickets_dir, "#{issue.identifier}.md"), """
    ---
    title: Attachments follow their source document
    priority: high
    estimate: 3
    ---

    Journal entries show the attachments of the document they came from.
    """)

    LinearMock.mock_update_issue_success(%{"id" => issue.external_id})

    expect(Runs, :start_os_process, fn %Run{} = run, _argv ->
      {:ok, %OsProcess{task_id: task_id, run: run, task: Repo.get!(Task, task_id)}}
    end)

    assert {:ok, %OsProcess{task: %Task{id: ^task_id, stage: :design}}} =
             Pipeline.approve_product_task(task)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :product_approved}}

    assert %Issue{
             title: "Attachments follow their source document",
             priority: :high,
             estimate: 3,
             description: description
           } =
             Repo.get!(Issue, issue.id)

    assert description =~ "Journal entries show the attachments"
  end

  test "opens an issue for every ticket the run split out", %{task: task, issue: issue, tickets_dir: tickets_dir} do
    File.write!(Path.join(tickets_dir, "#{issue.identifier}.md"), "---\ntitle: The kept ticket\n---\n\nThe kept body.\n")
    File.write!(Path.join(tickets_dir, "split-1.md"), "---\ntitle: The split ticket\n---\n\nThe split body.\n")

    LinearMock.mock_update_issue_success(%{"id" => issue.external_id})

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_approve_product_split_1",
      "identifier" => "APT-2",
      "title" => "The split ticket"
    })

    expect(Runs, :start_os_process, fn %Run{} = run, _argv ->
      {:ok, %OsProcess{run: run, task: Repo.get!(Task, task.id)}}
    end)

    assert {:ok, %OsProcess{task: %Task{stage: :design}}} = Pipeline.approve_product_task(task)

    assert %Issue{title: "The split ticket"} = Repo.get_by!(Issue, identifier: "APT-2")
  end

  test "refuses a task that is not awaiting approval", %{project: project, task_attrs: task_attrs} do
    task =
      %Task{}
      |> Task.changeset(%{task_attrs | stage_state: :running}, project.id)
      |> Repo.insert!()

    assert {:error, {:invalid_stage_state, :running}} =
             Pipeline.approve_product_task(task)
  end

  test "refuses a task that is past the product stage", %{project: project, task_attrs: task_attrs} do
    task =
      %Task{}
      |> Task.changeset(%{task_attrs | stage: :engineer}, project.id)
      |> Repo.insert!()

    assert {:error, {:invalid_stage, :engineer}} =
             Pipeline.approve_product_task(task)
  end

  test "records the error when the run left no ticket", %{task: task} do
    assert {:error, :no_ticket} = Pipeline.approve_product_task(task)

    assert %Task{stage: :product, stage_state: :awaiting_approval, error: error} = Repo.get!(Task, task.id)
    assert error =~ "no ticket"
  end

  test "records the error when Linear rejects the ticket", %{task: task, issue: issue, tickets_dir: tickets_dir} do
    File.write!(Path.join(tickets_dir, "#{issue.identifier}.md"), "---\ntitle: The ticket\n---\n\nThe body.\n")
    LinearMock.mock_api_error(500, %{"error" => "boom"})

    assert {:error, {:push_failed, _reason}} = Pipeline.approve_product_task(task)

    assert %Task{stage: :product, stage_state: :awaiting_approval, error: error} = Repo.get!(Task, task.id)
    assert error =~ "Failed to publish the ticket"
  end
end
