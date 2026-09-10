defmodule RailTest.RolesHelpers do
  @moduledoc false

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run
  alias Rail.Runs.Schemas.RunEvent

  def create_test_project(attrs \\ %{}) do
    attrs = Map.new(attrs)
    id = System.unique_integer([:positive])

    default_attrs = %{
      name: "Project #{id}",
      github_repo: "example/repo-#{id}",
      github_installation_id: id,
      default_branch: "main",
      linear_team_id: "team_#{id}",
      linear_team_key: "P#{id}",
      clone_path: "/tmp/repo-#{id}",
      active: true
    }

    merged = Map.merge(default_attrs, attrs)

    %Project{}
    |> Project.changeset(merged)
    |> Repo.insert!()
  end

  def create_test_role(attrs \\ %{}) do
    attrs = Map.new(attrs)
    id = System.unique_integer([:positive])
    project_id = attrs[:project_id] || attrs["project_id"] || create_test_project().id

    default_attrs = %{
      name: "Role #{id}",
      description: "Description for role #{id}",
      icon_name: "hero-command-line",
      cli_backend: :claude,
      model: "claude-3-7-sonnet",
      reasoning_effort: :high,
      system_prompt: "You are an expert agent for role #{id}.",
      max_concurrent: 1,
      position: 0
    }

    merged = Map.merge(default_attrs, attrs)

    %Role{}
    |> Role.changeset(merged, project_id)
    |> Repo.insert!()
  end

  def create_test_role_run(attrs \\ %{}) do
    attrs = Map.new(attrs)
    id = System.unique_integer([:positive])
    role_id = attrs[:role_id] || attrs["role_id"] || UXID.generate!(prefix: "rol")
    task_id = attrs[:task_id] || attrs["task_id"] || UXID.generate!(prefix: "tsk")

    default_attrs = %{
      role_id: role_id,
      task_id: task_id,
      status: :finished,
      started_at: DateTime.utc_now(),
      completed_at: DateTime.shift(DateTime.utc_now(), second: 10),
      output: "Standard run output #{id}",
      exit_code: 0,
      attempts: 1,
      pruned: false
    }

    merged = Map.merge(default_attrs, attrs)

    %RoleRun{}
    |> RoleRun.changeset(merged)
    |> Repo.insert!()
  end

  def create_test_run_event(attrs \\ %{}) do
    attrs = Map.new(attrs)
    role_run_id = attrs[:role_run_id] || attrs["role_run_id"] || create_test_role_run().id
    seq = attrs[:seq] || attrs["seq"] || 1
    line = attrs[:line] || attrs["line"] || "Log event line"
    inserted_at = attrs[:inserted_at] || attrs["inserted_at"]

    if inserted_at do
      Repo.insert!(%RunEvent{
        role_run_id: role_run_id,
        seq: seq,
        line: line,
        inserted_at: inserted_at,
        updated_at: inserted_at
      })
    else
      %RunEvent{}
      |> RunEvent.changeset(%{role_run_id: role_run_id, seq: seq, line: line})
      |> Repo.insert!()
    end
  end

  def create_test_run(attrs \\ %{}) do
    attrs = Map.new(attrs)
    role_run_id = attrs[:role_run_id] || attrs["role_run_id"] || create_test_role_run().id
    task_id = attrs[:task_id] || attrs["task_id"] || UXID.generate!(prefix: "tsk")

    default_attrs = %{
      role_run_id: role_run_id,
      task_id: task_id,
      kind: :stage,
      stream_path: "/tmp/axis/streams/test_#{System.unique_integer([:positive])}.ndjson",
      node: to_string(Node.self()),
      boot_id: UXID.generate!(),
      status: :running,
      started_at: DateTime.utc_now()
    }

    merged = Map.merge(default_attrs, attrs)

    %Run{}
    |> Run.changeset(merged)
    |> Repo.insert!()
  end
end
