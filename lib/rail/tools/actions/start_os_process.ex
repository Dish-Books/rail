defmodule Rail.Tools.Actions.StartOsProcess do
  @moduledoc false

  import Rail.Tools.Utils.PlaceOnAccount

  alias Rail.Mcp
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Starts a detached CLI runner for a run in a sandbox of its own, records the
  row, starts its Follower, and settles the dispatch either way.

  The turn runs on the account its conversation lives on, or the one with the
  most usage to spare. When every account it could go to is used up, it waits
  for usage. A sandbox holds what the run's role reserves; when the machine lacks
  that, the row waits in line. Either way the run reads as waiting and starts on
  its own.

  Everything the spawn needs is derived from the run: the CLI and model from its
  role, the executable and config directory from the account it is placed on,
  and the working directory and stream path from its task. `argv` is arguments only. Nothing is wired in for
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
    run = Repo.preload(run, [:role, task: :project])
    %Run{task: %Task{} = task, role: %Role{}} = run

    stream_path = prepare_stream_files(task, run)
    {token, token_hash} = Mcp.issue_run_token()
    os_process = insert_os_process(run, stream_path, token_hash)

    case place_on_account(os_process, run, argv, token) do
      {:ok, os_process} -> finalize(task, run, os_process)
      {:waiting, os_process} -> finalize(task, %{run | status: :waiting_for_resources}, os_process)
      {:waiting_for_usage, os_process, _resets_at} -> finalize(task, %{run | status: :waiting_for_usage}, os_process)
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
end
