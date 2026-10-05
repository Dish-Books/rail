defmodule Rail.Tools.Utils.PlaceOnAccount do
  @moduledoc false

  import Ecto.Query
  import Rail.Tools.Utils.BackendEnv
  import Rail.Tools.Utils.EnqueueSandbox
  import Rail.Tools.Utils.EnsureExecutable
  import Rail.Tools.Utils.PickBackend
  import Rail.Tools.Utils.TrustWorkspace
  import Rail.Tools.Utils.WorktreeEnv

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools.Schemas.Backend
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Tools.Workers.StartAfterUsageReset

  @doc """
  Puts an agent turn on an account and hands it to the sandbox line: the one its
  conversation lives on when `run` is resumable, or the one standing highest.

  The pick and the stamp are one step on this machine, so turns started together
  see each other and split across accounts. When every account it could go to is
  used up, the row waits for usage instead, holding no reservation and keeping
  `argv` and `token` until a job at the earliest reset places it again. A turn
  that can only go to a signed-out account joins the line on it, and the line
  holds it until that account is signed in. `run` carries its task, down to the
  project, and its role.

  Returns what `enqueue_sandbox/3` does, `{:waiting_for_usage, os_process,
  resets_at}`, or `{:error, reason}` with the row failed to start.
  """
  def place_on_account(%OsProcess{} = os_process, %Run{task: %Task{} = task, role: %Role{} = role} = run, argv, token) do
    pinned = pinned(run)

    placed =
      :global.trans({:rail_account_placement, self()}, fn ->
        case pick_backend(role.cli, role.model, pinned) do
          {placed, backend} when placed in [:ok, :held] ->
            {:ok, backend, os_process |> OsProcess.changeset(%{backend_id: backend.id}) |> Repo.update!()}

          wait_or_refusal ->
            wait_or_refusal
        end
      end)

    case placed do
      {:ok, backend, stamped} ->
        with :ok <- ensure_executable(backend.executable_path, stamped, run) do
          enqueue_sandbox(stamped, run, launch_spec(backend, argv, stamped.stream_path, task, token))
        end

      {:wait, resets_at} ->
        park(os_process, run, pinned, %{"argv" => argv, "token" => token}, resets_at)

      {:error, :no_account} ->
        refuse(os_process, Backend.no_account_error(role.model, role.name))

      {:error, {:unavailable, backend}} ->
        refuse(
          os_process,
          "This conversation lives on #{Backend.display_name(backend)}, which Rail cannot run. " <>
            "Fix it on Settings › Backends to continue it."
        )
    end
  end

  # A conversation lives on the account its latest placed turn ran on.
  defp pinned(%Run{id: run_id} = run) do
    if Run.resumable?(run) do
      Repo.one(
        from b in Backend,
          join: p in OsProcess,
          on: p.backend_id == b.id,
          where: p.run_id == ^run_id and p.kind == :agent,
          order_by: [desc: p.inserted_at, desc: p.id],
          limit: 1
      )
    end
  end

  # A turn pinned to its account keeps that account on the row while it waits; one
  # that could go anywhere has no account yet.
  defp park(%OsProcess{} = os_process, %Run{} = run, pinned, kept, resets_at) do
    parked =
      os_process
      |> OsProcess.changeset(%{
        status: :waiting_for_usage,
        queued_at: DateTime.utc_now(),
        backend_id: pinned && pinned.id,
        launch: Jason.encode!(kept)
      })
      |> Repo.update!()

    {:ok, _waiting} = Pipeline.update_run(run, %{status: :waiting_for_usage})

    at = Calendar.strftime(resets_at, "%-I:%M %p UTC on %b %-d")

    line =
      case pinned do
        %Backend{} ->
          "[rail] This conversation lives on #{Backend.display_name(pinned)}, which has used up its usage, " <>
            "so this turn waits for it. It starts on its own when it resets, at #{at}."

        nil ->
          "[rail] Every signed-in account offering #{run.role.model} has used up its usage, so this turn waits. " <>
            "It starts on its own when the earliest resets, at #{at}."
      end

    Pipeline.append_run_events(run.id, parked.id, [line])
    {:ok, _job} = %{os_process_id: parked.id} |> StartAfterUsageReset.new(scheduled_at: resets_at) |> Oban.insert()
    Phoenix.PubSub.broadcast(Rail.PubSub, "run:#{run.id}", {:run_changed, run.id})

    {:waiting_for_usage, parked, resets_at}
  end

  defp refuse(%OsProcess{} = os_process, error) do
    os_process
    |> OsProcess.changeset(%{
      status: :failed,
      ended_reason: :failed_to_start,
      ended_at: DateTime.utc_now(),
      exit_code: -1,
      launch: nil
    })
    |> Repo.update!()

    {:error, error}
  end

  # The clone is trusted along with the worktree: Claude Code keys a worktree's
  # trust to the repository it belongs to.
  defp launch_spec(backend, argv, stream_path, %Task{project: %Project{} = project} = task, token) do
    trust_workspace(backend, [project.clone_path, task.worktree_path])
    {args, stdin_path} = prompt_on_stdin(argv, stream_path)
    args = system_prompt_in_file(args, stream_path)

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
  defp prompt_on_stdin(["-p", prompt | rest], stream_path) when is_binary(prompt) do
    prompt_path = "#{stream_path}.prompt"
    File.write!(prompt_path, prompt)
    {["-p" | rest], prompt_path}
  end

  defp prompt_on_stdin(argv, _stream_path), do: {argv, nil}

  # The role's prompt goes in a file for the same reason, and for one more: in
  # argv it is in the agent's command line, where `pgrep -f` reads it. A demo
  # prompt that says `mix phx.server` made the agent's own process match the
  # `pgrep -f "mix phx.server"` it ran to stop its server in the worktree, so it
  # killed itself and the run ended "Exited with code 143".
  defp system_prompt_in_file(args, stream_path) do
    case Enum.split_while(args, &(&1 != "--append-system-prompt")) do
      {before, ["--append-system-prompt", system_prompt | rest]} ->
        system_prompt_path = "#{stream_path}.system-prompt"
        File.write!(system_prompt_path, system_prompt)
        before ++ ["--append-system-prompt-file", system_prompt_path | rest]

      {_all, []} ->
        args
    end
  end
end
