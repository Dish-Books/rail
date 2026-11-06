defmodule Rail.Workflows.Actions.SyncWorkflowsTest do
  use Rail.DataCase, async: true

  import ExUnit.CaptureLog

  alias Rail.Git
  alias Rail.Projects
  alias Rail.Workflows
  alias Rail.Workflows.Schemas.Workflow
  alias Rail.Workflows.Schemas.WorkflowDefinition

  @weekly """
  name: Dependency updates
  schedule: "0 9 * * 1"
  instructions: Update the dependencies.
  """

  setup do
    # The files on the project's fetched default branch, as `Rail.Git` lists and reads them.
    branch = start_supervised!({Agent, fn -> %{} end})

    stub(Git, :list_default_branch_files, fn _project, ".rail/workflows" ->
      {:ok, Enum.sort(Agent.get(branch, &Map.keys/1))}
    end)

    stub(Git, :read_default_branch_file, fn _project, path ->
      with :error <- Agent.get(branch, &Map.fetch(&1, path)),
           do: {:error, "fatal: path '#{path}' does not exist in 'refs/remotes/origin/main'"}
    end)

    # Merges `files` to the default branch, writing nil as a removal.
    merge = fn files ->
      Agent.update(branch, fn merged ->
        Enum.reduce(files, merged, fn
          {path, nil}, merged -> Map.delete(merged, path)
          {path, text}, merged -> Map.put(merged, path, text)
        end)
      end)
    end

    # 2026-10-12 is a Monday.
    stub(DateTime, :utc_now, fn -> ~U[2026-10-12 08:00:00.000000Z] end)
    Phoenix.PubSub.subscribe(Rail.PubSub, "workflows")

    %{merge: merge}
  end

  test "a merged workflow file becomes a row with its definition and next due time", %{
    project: %{id: project_id} = project,
    merge: merge
  } do
    merge.(%{".rail/workflows/dependency-updates.yml" => @weekly, ".rail/workflows/notes.md" => "Not a workflow"})

    assert {:ok, 1} = Workflows.sync_workflows(project)

    assert {:ok,
            [
              %Workflow{
                project_id: ^project_id,
                path: ".rail/workflows/dependency-updates.yml",
                paused: false,
                next_run_at: ~U[2026-10-12 09:00:00Z],
                definition: %WorkflowDefinition{
                  name: "Dependency updates",
                  schedule: "0 9 * * 1",
                  instructions: "Update the dependencies."
                }
              }
            ]} = Workflows.list_workflows(system_scope(), [])

    assert_receive {:workflows_changed, ^project_id}
  end

  test "an invalid file becomes a row with no definition and no due time, logged once each time it turns invalid", %{
    project: project,
    merge: merge
  } do
    merge.(%{".rail/workflows/broken.yaml" => "name: Broken\nschedule: whenever\ninstructions: Go\n"})

    log = capture_log(fn -> assert {:ok, 1} = Workflows.sync_workflows(project) end)
    assert log =~ "Test Project's .rail/workflows/broken.yaml is invalid, so it starts nothing: schedule is not a cron"
    assert {:ok, [%Workflow{definition: nil, next_run_at: nil}]} = Workflows.list_workflows(system_scope(), [])

    # Other async tests log too, so only this file's warning is looked for.
    refute capture_log(fn -> assert {:ok, 0} = Workflows.sync_workflows(project) end) =~ "broken.yaml"

    merge.(%{".rail/workflows/broken.yaml" => @weekly})
    assert {:ok, 1} = Workflows.sync_workflows(project)
    assert {:ok, [%Workflow{next_run_at: ~U[2026-10-12 09:00:00Z]}]} = Workflows.list_workflows(system_scope(), [])

    merge.(%{".rail/workflows/broken.yaml" => "name: ["})
    assert capture_log(fn -> assert {:ok, 1} = Workflows.sync_workflows(project) end) =~ "not YAML"
    assert {:ok, [%Workflow{definition: nil, next_run_at: nil}]} = Workflows.list_workflows(system_scope(), [])
  end

  test "a file whose skip names a map is invalid, and the valid file beside it still syncs", %{
    project: project,
    merge: merge
  } do
    merge.(%{
      ".rail/workflows/dependency-updates.yml" => @weekly,
      ".rail/workflows/sweep.yml" => "name: Sweep\nschedule: \"0 6 * * *\"\ninstructions: Go\nskip:\n  - product: true\n"
    })

    capture_log(fn -> assert {:ok, 2} = Workflows.sync_workflows(project) end)
    {:ok, workflows} = Workflows.list_workflows(system_scope(), [])

    assert %Workflow{definition: nil, next_run_at: nil} = Enum.find(workflows, &(&1.path == ".rail/workflows/sweep.yml"))

    assert %Workflow{definition: %WorkflowDefinition{name: "Dependency updates"}} =
             Enum.find(workflows, &(&1.path == ".rail/workflows/dependency-updates.yml"))
  end

  test "a file git cannot read starts nothing, the same as one that does not parse", %{project: project, merge: merge} do
    merge.(%{".rail/workflows/dependency-updates.yml" => @weekly})
    expect(Git, :read_default_branch_file, fn _project, _path -> {:error, "fatal: bad object"} end)

    assert capture_log(fn -> assert {:ok, 1} = Workflows.sync_workflows(project) end) =~ "fatal: bad object"
    assert {:ok, [%Workflow{definition: nil, next_run_at: nil}]} = Workflows.list_workflows(system_scope(), [])
  end

  test "a changed schedule moves the due time, and a pause survives the change", %{project: project, merge: merge} do
    merge.(%{".rail/workflows/dependency-updates.yml" => @weekly})
    {:ok, 1} = Workflows.sync_workflows(project)
    {:ok, [workflow]} = Workflows.list_workflows(system_scope(), [])
    {:ok, %Workflow{paused: true}} = Workflows.set_workflow_paused(system_scope(), workflow, true)

    merge.(%{".rail/workflows/dependency-updates.yml" => String.replace(@weekly, "Update", "Bump")})
    assert {:ok, 1} = Workflows.sync_workflows(project)

    assert {:ok,
            [%Workflow{paused: true, next_run_at: ~U[2026-10-12 09:00:00Z], definition: %{instructions: "Bump" <> _rest}}]} =
             Workflows.list_workflows(system_scope(), [])

    merge.(%{".rail/workflows/dependency-updates.yml" => String.replace(@weekly, "0 9 * * 1", "0 6 * * *")})
    assert {:ok, 1} = Workflows.sync_workflows(project)

    assert {:ok, [%Workflow{paused: true, next_run_at: ~U[2026-10-13 06:00:00Z]}]} =
             Workflows.list_workflows(system_scope(), [])
  end

  test "a removed file's row is marked, listed no more and never due, and comes back with its file", %{
    project: project,
    merge: merge
  } do
    merge.(%{".rail/workflows/dependency-updates.yml" => @weekly})
    {:ok, 1} = Workflows.sync_workflows(project)

    merge.(%{".rail/workflows/dependency-updates.yml" => nil})
    assert {:ok, 1} = Workflows.sync_workflows(project)

    assert [%Workflow{removed_at: %DateTime{}, next_run_at: nil, definition: %{name: "Dependency updates"}}] =
             Repo.all(Workflow)

    assert {:ok, []} = Workflows.list_workflows(system_scope(), [])
    assert {:ok, []} = Workflows.list_workflows(system_scope(), due: ~U[2027-01-01 00:00:00Z])
    assert {:ok, 0} = Workflows.sync_workflows(project)

    merge.(%{".rail/workflows/dependency-updates.yml" => @weekly})
    assert {:ok, 1} = Workflows.sync_workflows(project)

    assert {:ok, [%Workflow{removed_at: nil, next_run_at: ~U[2026-10-12 09:00:00Z]}]} =
             Workflows.list_workflows(system_scope(), [])
  end

  # A project of its own, since other tests announce changes to the seeded one.
  test "a sync that changes nothing writes and broadcasts nothing", %{project: seeded, merge: merge} do
    {:ok, %{id: project_id} = project} =
      Projects.create_project(system_scope(), %{
        name: "Quiet workflows",
        github_repo: "example/quiet-workflows",
        github_installation_id: 1,
        default_branch: "main",
        key: "QWF",
        clone_path: seeded.clone_path
      })

    merge.(%{".rail/workflows/dependency-updates.yml" => @weekly})
    {:ok, 1} = Workflows.sync_workflows(project)
    assert_receive {:workflows_changed, ^project_id}

    assert {:ok, 0} = Workflows.sync_workflows(project)
    refute_receive {:workflows_changed, ^project_id}, 50
  end

  test "a project whose clone never fetched its default branch says so and changes nothing", %{project: project} do
    expect(Git, :list_default_branch_files, fn _project, ".rail/workflows" ->
      {:error, "fatal: Not a valid object name refs/remotes/origin/main"}
    end)

    assert {:error, "fatal: Not a valid object name refs/remotes/origin/main"} = Workflows.sync_workflows(project)
    assert [] = Repo.all(Workflow)
  end
end
