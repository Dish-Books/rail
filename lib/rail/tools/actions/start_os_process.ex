defmodule Rail.Tools.Actions.StartOsProcess do
  @moduledoc false

  import Rail.Tools.Utils.BackendEnv
  import Rail.Tools.Utils.EnqueueSandbox
  import Rail.Tools.Utils.EnsureExecutable
  import Rail.Tools.Utils.TrustWorkspace
  import Rail.Tools.Utils.WorktreeEnv

  alias Rail.Mcp
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools.Schemas.Backend
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Starts a detached CLI runner for a run in a sandbox of its own, records the
  row, starts its Follower, and settles the dispatch either way.

  A sandbox holds what the run's role reserves. When the machine lacks that, the
  row waits in line, the run reads as waiting, and it starts on its own once
  enough is free.

  Everything the spawn needs is derived from the run: the executable and the
  account's config directory from its role's backend, and the working directory and
  stream path from its task. `argv` is arguments only. Nothing is wired in for
  the exit: `run_finished/3` works from the row the spawn writes.

  A spawn is a spawn whether it carries a stage's work or a message the human
  just typed, so nothing here asks which it was and nothing here touches the
  task. Returns `{:ok, os_process}` with its `:run` and `:task` loaded, running or
  waiting, or
  `{:error, {:spawn_failed, reason, run}}` with the reason recorded on the run.

  Returns `{:error, :dispatch_disabled}` when dispatch is switched off. This is
  the one gate on invoking an agent CLI, so
  it sits here rather than at each of the places that decide to: Rail still moves
  tasks, records runs and renders everything, it just never spawns.
  """
  def start_os_process(%Run{} = run, argv) do
    if dispatch_disabled?() do
      {:error, :dispatch_disabled}
    else
      spawn_os_process(run, argv)
    end
  end

  defp dispatch_disabled?, do: Application.get_env(:rail, :no_dispatch, false)

  defp spawn_os_process(%Run{} = run, argv) do
    run = Repo.preload(run, task: :project, role: :backend)
    %Run{task: %Task{} = task, role: %Role{backend: %Backend{} = backend}} = run

    stream_path = prepare_stream_files(task, run)
    {token, token_hash} = Mcp.issue_run_token()
    os_process = insert_os_process(run, stream_path, token_hash)

    result =
      with :ok <- ensure_executable(backend.executable_path, os_process, run) do
        enqueue_sandbox(os_process, run, launch_spec(backend, argv, stream_path, task, token))
      end

    case result do
      {:ok, os_process} -> finalize(task, run, os_process)
      {:waiting, os_process} -> finalize(task, %{run | status: :waiting_for_resources}, os_process)
      {:error, reason} -> fail(run, reason, Repo.get!(OsProcess, os_process.id))
    end
  end

  defp finalize(task, run, os_process) do
    {:ok, run} = Pipeline.update_run(run, %{pending_answer: nil, error: nil})

    {:ok, %{os_process | run: run, task: task}}
  end

  # A turn that never started, refused by the line or failed at launch, settles its
  # run as failed, as one admitted later from the line does: a run left running with
  # no process behind it is one nothing recovers. The run then keeps those words, as
  # it keeps the missing binary check's, which settled it before returning here.
  defp fail(run, reason, %OsProcess{status: :failed, ended_reason: :failed_to_start} = os_process) do
    error = if is_binary(reason), do: reason, else: "Could not start its sandbox: #{inspect(reason)}"
    {:ok, _settled} = Pipeline.run_finished(os_process, %{exit_code: -1, error: error})
    Phoenix.PubSub.broadcast(Rail.PubSub, "run:#{run.id}", {:run_changed, run.id})
    fail(run, reason, nil)
  end

  defp fail(run, reason, _started_or_settled) do
    {:ok, run} = Pipeline.get_run(run.id)

    {:ok, run} =
      if is_binary(run.error) do
        {:ok, run}
      else
        Pipeline.update_run(run, %{error: "Failed to spawn runner: #{inspect(reason)}"})
      end

    {:error, {:spawn_failed, reason, run}}
  end

  defp insert_os_process(run, stream_path, token_hash) do
    attrs = %{
      run_id: run.id,
      task_id: run.task_id,
      stream_path: stream_path,
      status: :starting,
      started_at: DateTime.utc_now(),
      mcp_token_hash: token_hash
    }

    %OsProcess{}
    |> OsProcess.changeset(attrs)
    |> Repo.insert!()
  end

  # One stream per run, under the task's scratch directory, so concurrent runs
  # on a task cannot truncate each other's logs.
  defp prepare_stream_files(%Task{scratch_path: scratch_path}, %Run{id: id}) do
    stream_path = Path.join([scratch_path, "streams", "#{id}.ndjson"])
    stream_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(stream_path, "")
    File.write!("#{stream_path}.err", "")
    stream_path
  end

  # The clone is trusted along with the worktree: Claude Code keys a worktree's
  # trust to the repository it belongs to.
  defp launch_spec(backend, argv, stream_path, %Task{project: %Project{} = project} = task, token) do
    trust_workspace(backend, [project.clone_path, task.worktree_path])
    {args, stdin_path} = prompt_on_stdin(backend, argv, stream_path)

    %{
      "executable" => backend.executable_path,
      "args" => args,
      "env" => task |> worktree_env() |> Map.merge(backend_env(backend)) |> Map.put("RAIL_MCP_TOKEN", token),
      "cwd" => task.worktree_path,
      "stdout_path" => stream_path,
      "stderr_path" => "#{stream_path}.err",
      "stdin_path" => stdin_path
    }
  end

  # Claude's prompt goes in on stdin rather than in argv. Linux refuses to exec
  # with any one argument over 128KB (E2BIG), and a brief carrying an approved
  # design's whole page runs past that, so the CLI never started and the run
  # ended "Exited with code 7" with nothing in either stream. `-p` is Claude's
  # --print flag, and with no prompt argument it reads the prompt from stdin.
  # The file sits beside the run's stream, so what the agent was sent can be read
  # back later.
  defp prompt_on_stdin(%Backend{name: :claude}, ["-p", prompt | rest], stream_path) when is_binary(prompt) do
    prompt_path = "#{stream_path}.prompt"
    File.write!(prompt_path, prompt)
    {["-p" | rest], prompt_path}
  end

  defp prompt_on_stdin(_backend, argv, _stream_path), do: {argv, nil}
end
