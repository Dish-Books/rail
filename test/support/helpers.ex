defmodule RailTest.Helpers do
  @moduledoc false

  alias Rail.Issues.Schemas.Issue

  defdelegate create_temp_git_repo(opts \\ []), to: RailTest.GitHelpers
  defdelegate git!(dir, args), to: RailTest.GitHelpers

  defdelegate stub_slack(opts \\ []), to: RailTest.TriageHelpers
  defdelegate connect_slack_channel(project, opts \\ []), to: RailTest.TriageHelpers
  defdelegate slack_message_event(channel, fields), to: RailTest.TriageHelpers
  defdelegate triage_project(), to: RailTest.TriageHelpers
  defdelegate triage_with(thread, result), to: RailTest.TriageHelpers
  defdelegate triage_bug(overrides \\ %{}), to: RailTest.TriageHelpers
  defdelegate slack_user(team_id, name \\ "Michael"), to: RailTest.TriageHelpers

  defdelegate stub_vertex(vectors \\ %{}), to: RailTest.LearningsHelpers
  defdelegate stub_vertex_down(), to: RailTest.LearningsHelpers
  defdelegate vector(components), to: RailTest.LearningsHelpers
  defdelegate far(), to: RailTest.LearningsHelpers
  defdelegate learning(project, attrs, overrides \\ []), to: RailTest.LearningsHelpers
  defdelegate learnings_task(project, identifier, stage \\ :engineer), to: RailTest.LearningsHelpers

  @doc """
  Runs `fun` until its assertions hold, or `timeout` passes.

  Anything a timer drives - a tail poll, a batch tick, a process noticing it has
  exited - lands when the scheduler gets to it, not when a fixed sleep says it
  should. Sleeping for the interval and asserting once passes on an idle machine
  and fails on a loaded one; this waits for the state the test is actually about.
  """
  def eventually(fun, timeout \\ 2_000) when is_function(fun, 0) do
    attempt(fun, System.monotonic_time(:millisecond) + timeout)
  end

  @doc """
  An account signed in and offering `models`, its usage windows as a probe would
  store them: `windows` are `{label, percent left, resets_at}`. Takes the backend's
  own fields too, such as `:label`, `:name` and `:executable_path`.
  """
  def ready_backend(models, windows \\ [], attrs \\ %{}) do
    {:ok, backend} =
      Rail.Tools.create_backend(
        Rail.Scope.for_system(),
        Map.merge(
          %{
            name: :claude,
            executable_path: "/usr/bin/true",
            models: Enum.map(List.wrap(models), &%{id: &1, display_name: &1})
          },
          Map.take(attrs, [:name, :label, :executable_path])
        )
      )

    usage =
      for {label, percent, resets_at} <- windows do
        at = if resets_at, do: DateTime.to_iso8601(resets_at)
        %{name: label, details: %{"windows" => [%{"label" => label, "remaining_percent" => percent, "resets_at" => at}]}}
      end

    backend
    |> Rail.Tools.Schemas.Backend.usage_changeset(
      Map.merge(%{name: backend.name, status: :ready, usage: usage}, Map.take(attrs, [:status, :account_label]))
    )
    |> Rail.Repo.update!()
  end

  @doc """
  A run of the seeded engineer role, set to `model`, on a task of its own with a
  worktree and scratch directory on disk, ready for `Rail.Tools.start_os_process/2`.
  """
  def agent_run(%Rail.Projects.Schemas.Project{} = project, model) do
    unique = System.unique_integer([:positive])
    tmp_dir = Path.join(System.tmp_dir!(), "agent_run_#{unique}")
    File.mkdir_p!(Path.join(tmp_dir, "worktree"))
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(tmp_dir) end)

    {:ok, seeded} = Rail.Roles.get_role(project_id: project.id, stage: :engineer)
    {:ok, role} = Rail.Roles.update_role(Rail.Scope.for_system(), seeded, %{model: model})

    issue =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_agent_run_#{unique}",
        identifier: "RUN#{unique}-1",
        title: "Agent Run Issue",
        state: :backlog
      })
      |> Rail.Repo.insert!()

    task =
      %Rail.Pipeline.Schemas.Task{}
      |> Rail.Pipeline.Schemas.Task.changeset(
        %{
          issue_id: issue.id,
          stage: :engineer,
          worktree_name: "agent-run-#{unique}",
          worktree_path: Path.join(tmp_dir, "worktree"),
          scratch_path: Path.join(tmp_dir, "scratch")
        },
        project.id
      )
      |> Rail.Repo.insert!()

    {:ok, run} =
      Rail.Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :starting, started_at: DateTime.utc_now()})

    run
  end

  @doc """
  An implementation plan in the section format the Architect prompt asks for, with
  both diagrams and a Program design.
  """
  def sheet_plan, do: File.read!("test/support/fixtures/sheet_plan.md")

  @doc """
  Puts a session token for `user` on `conn` so requests are authenticated.
  """
  def log_in_user(conn, user) do
    token = Rail.Users.generate_user_session_token(user)

    conn
    |> Map.replace!(:secret_key_base, RailWeb.Endpoint.config(:secret_key_base))
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  defp attempt(fun, deadline) do
    fun.()
  rescue
    error ->
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        attempt(fun, deadline)
      else
        reraise error, __STACKTRACE__
      end
  end
end
