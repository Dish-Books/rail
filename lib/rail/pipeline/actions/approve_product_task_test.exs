defmodule Rail.Pipeline.Actions.ApproveProductTaskTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs.Schemas.Run
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
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

    scratch_dir = temp_scratch_dir()
    task = insert_task(project, issue)

    %{scope: scope, project: project, issue: issue, task: task, scratch_dir: scratch_dir}
  end

  test "publishes the ticket, adopts it, and starts the design run", %{
    task: task,
    issue: issue,
    scratch_dir: scratch_dir
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    write_ticket(scratch_dir, issue.identifier, """
    ---
    title: Attachments follow their source document
    priority: high
    estimate: 3
    ---

    Journal entries show the attachments of the document they came from.
    """)

    LinearMock.mock_update_issue_success(%{"id" => issue.external_id})

    task_id = task.id

    assert {:ok, %{task: %Task{id: ^task_id, stage: :design, stage_state: :running}, run: %Run{}}} =
             Pipeline.approve_product_task(task,
               scratch_dir: scratch_dir,
               executable: System.find_executable("true") || "/usr/bin/true",
               skip_follower: true
             )

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

  test "opens an issue for every ticket the run split out", %{task: task, issue: issue, scratch_dir: scratch_dir} do
    write_ticket(scratch_dir, issue.identifier, "---\ntitle: The kept ticket\n---\n\nThe kept body.\n")
    write_ticket(scratch_dir, "split-1", "---\ntitle: The split ticket\n---\n\nThe split body.\n")

    LinearMock.mock_update_issue_success(%{"id" => issue.external_id})

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_approve_product_split_1",
      "identifier" => "APT-2",
      "title" => "The split ticket"
    })

    assert {:ok, %{task: %Task{stage: :design}}} =
             Pipeline.approve_product_task(task,
               scratch_dir: scratch_dir,
               executable: System.find_executable("true") || "/usr/bin/true",
               skip_follower: true
             )

    assert %Issue{title: "The split ticket"} = Repo.get_by!(Issue, identifier: "APT-2")
  end

  test "refuses a task that is not awaiting approval", %{project: project, issue: issue, scratch_dir: scratch_dir} do
    task = insert_task(project, issue, stage_state: :running)

    assert {:error, {:invalid_stage_state, :running}} =
             Pipeline.approve_product_task(task, scratch_dir: scratch_dir)
  end

  test "refuses a task that is past the product stage", %{project: project, issue: issue, scratch_dir: scratch_dir} do
    task = insert_task(project, issue, stage: :engineer)

    assert {:error, {:invalid_stage, :engineer}} =
             Pipeline.approve_product_task(task, scratch_dir: scratch_dir)
  end

  test "records the error when the run left no ticket", %{task: task, scratch_dir: scratch_dir} do
    assert {:error, :no_ticket} = Pipeline.approve_product_task(task, scratch_dir: scratch_dir)

    assert %Task{stage: :product, stage_state: :awaiting_approval, error: error} = Repo.get!(Task, task.id)
    assert error =~ "no ticket"
  end

  test "records the error when Linear rejects the ticket", %{task: task, issue: issue, scratch_dir: scratch_dir} do
    write_ticket(scratch_dir, issue.identifier, "---\ntitle: The ticket\n---\n\nThe body.\n")
    LinearMock.mock_api_error(500, %{"error" => "boom"})

    assert {:error, {:push_failed, _reason}} = Pipeline.approve_product_task(task, scratch_dir: scratch_dir)

    assert %Task{stage: :product, stage_state: :awaiting_approval, error: error} = Repo.get!(Task, task.id)
    assert error =~ "Failed to publish the ticket"
  end

  defp insert_task(project, issue, attrs \\ []) do
    name = "apt-#{System.unique_integer([:positive])}"

    base = %{
      issue_id: issue.id,
      title: issue.title,
      description: issue.description,
      stage: :product,
      stage_state: :awaiting_approval,
      worktree_name: name,
      worktree_path: Path.join(project.clone_path, ".worktrees/#{name}")
    }

    %Task{}
    |> Task.changeset(Map.merge(base, Map.new(attrs)), project.id)
    |> Repo.insert!()
  end

  defp write_ticket(scratch_dir, name, content) do
    tickets_dir = Path.join(scratch_dir, "tickets")
    File.mkdir_p!(tickets_dir)
    tickets_dir |> Path.join("#{name}.md") |> File.write!(content)
  end

  defp temp_scratch_dir do
    dir = Path.join(System.tmp_dir!(), "rail_scratch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
