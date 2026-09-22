defmodule Rail.Pipeline.Actions.RunFinished do
  @moduledoc """
  The one thing that happens when an OS process exits.

  The run layer calls this from the process's own row, so it works the same
  whether the Follower saw the exit or `Rail.Tools.Boot` found the process already
  gone after a restart. Nothing is wired in at spawn time: the task, the run and
  the role are all on the row.

  There is no such thing as a chat turn here. A stage's own dispatch and a message
  the human typed are the same event — a process carrying this run exited — and
  they settle identically. What separates them is not how they started but what
  the agent said: the run is recorded, the questions it asked are filed, and a run
  that came back clean with nothing outstanding has its stage's finish applied. A
  run that stopped half way says nothing, so nothing happens to it, and the next
  message picks it up where it left off.

  A run that already had its say is latched at `stage_outcome: :done` and is left
  alone however many times it is messaged afterwards. `enter_stage/3` is what
  unlatches it, which is why nothing here moves a task: a stage's own finish
  does, when what it concluded leaves nobody anything to decide.
  """

  import Rail.Pipeline.Utils.ArchitectRunFinished
  import Rail.Pipeline.Utils.DemoRunFinished
  import Rail.Pipeline.Utils.DesignRunFinished
  import Rail.Pipeline.Utils.DispatchMessage
  import Rail.Pipeline.Utils.EngineerRunFinished
  import Rail.Pipeline.Utils.ProductRunFinished
  import Rail.Pipeline.Utils.QaRunFinished
  import Rail.Pipeline.Utils.QuestionQueue
  import Rail.Pipeline.Utils.RegisterAskedQuestions
  import Rail.Pipeline.Utils.ReviewRunFinished

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Settles the run whose OS process just exited, against `outcome`.
  """
  def run_finished(%OsProcess{} = os_process, outcome \\ %{}, opts \\ []) do
    case Repo.preload(os_process, [run: [:task, role: :backend]], force: true) do
      %OsProcess{run: %Run{task: %Task{}}} = os_process ->
        run =
          os_process
          |> settle_run(outcome)
          |> finish(os_process, opts)
          |> drain_queued_message(opts)

        {:ok, run}

      _unresolved ->
        {:error, :invalid_state}
    end
  end

  # Bookkeeping only: the process is marked finished and the run keeps what the
  # exit said about it. Nothing here decides anything — not whether the stage
  # moves, not whether the run is done. Usage accumulates rather than replacing: a
  # run outlives the processes carrying it and every one of them costs tokens.
  defp settle_run(%OsProcess{run: %Run{} = run} = os_process, outcome) do
    os_process |> OsProcess.changeset(%{status: :finished}) |> Repo.update!()

    attrs = %{
      status: settled_status(run),
      completed_at: run.completed_at || DateTime.utc_now(),
      exit_code: exit_code(outcome, run),
      error: error(outcome, run)
    }

    attrs =
      case usage(outcome) do
        %Run.Usage{} = usage -> Map.put(attrs, :usage, usage)
        nil -> attrs
      end

    {:ok, settled} = run |> Run.changeset(attrs) |> Repo.update()
    %{settled | task: run.task, role: run.role}
  end

  # A run parked on a question stays parked; the answer, not this exit, moves it.
  defp settled_status(%Run{status: :blocked_on_input}), do: :blocked_on_input
  defp settled_status(%Run{}), do: :finished

  defp said_it_was_done?(%Task{} = task) do
    task |> Repo.preload(:issue) |> Pipeline.read_commit_message() != nil
  end

  defp exit_code(%{exit_code: code}, _run) when is_integer(code), do: code
  defp exit_code(%{"exit_code" => code}, _run) when is_integer(code), do: code
  defp exit_code(_outcome, %Run{exit_code: code}) when is_integer(code), do: code
  defp exit_code(_outcome, _run), do: 0

  defp error(%{error: error}, _run) when is_binary(error), do: error
  defp error(%{"error" => error}, _run) when is_binary(error), do: error
  defp error(_outcome, %Run{error: error}) when is_binary(error), do: error
  defp error(_outcome, _run), do: nil

  defp usage(%{usage: %Run.Usage{} = usage}), do: usage
  defp usage(%{usage: usage}) when is_map(usage), do: struct(Run.Usage, usage)
  defp usage(%{"usage" => %Run.Usage{} = usage}), do: usage
  defp usage(%{"usage" => usage}) when is_map(usage), do: struct(Run.Usage, usage)
  defp usage(_other), do: nil

  defp finish(%Run{} = run, %OsProcess{} = os_process, opts) do
    case register_asked_questions(os_process, run) do
      [] -> maybe_finish(run, opts)
      _asked -> run
    end
  end

  defp maybe_finish(%Run{} = run, opts) do
    if concluded?(run) do
      run |> apply_finish(opts) |> latch_done()
    else
      run
    end
  end

  defp apply_finish(%Run{} = run, opts) do
    finish_action(run).(run, opts)
  rescue
    exception -> fail(run, Exception.message(exception))
  end

  defp fail(%Run{} = run, error) do
    {:ok, failed} = run |> Run.changeset(%{error: error}) |> Repo.update()
    %{failed | task: run.task, role: run.role}
  end

  defp concluded?(%Run{role: %Role{stage: stage}} = run) when stage in [:review, :qa, :demo] do
    run.exit_code == 0 and pending_questions(run.task_id) == []
  end

  # The engineer says it has finished by writing its commit message, and that is
  # a better signal than the exit code of the CLI carrying it: Agy exits non-zero
  # when its root agent stops with background tasks still running, having done
  # the work and said so. Throwing that turn away leaves the change sitting
  # uncommitted in the worktree with nothing to move it on.
  defp concluded?(%Run{role: %Role{stage: :engineer}, task: %Task{} = task} = run) do
    run.stage_outcome == :in_progress and
      pending_questions(run.task_id) == [] and
      (run.exit_code == 0 or said_it_was_done?(task))
  end

  # Every other run only concludes by saying so, having actually finished: a
  # non-zero exit and a task still parked on a question are both runs that have
  # not.
  defp concluded?(%Run{} = run) do
    run.stage_outcome == :in_progress and
      run.exit_code == 0 and
      pending_questions(run.task_id) == []
  end

  defp finish_action(%Run{role: %Role{stage: :product}}), do: &product_run_finished/2
  defp finish_action(%Run{role: %Role{stage: :design}}), do: &design_run_finished/2
  defp finish_action(%Run{role: %Role{stage: :architect}}), do: &architect_run_finished/2
  defp finish_action(%Run{role: %Role{stage: :engineer}}), do: &engineer_run_finished/2
  defp finish_action(%Run{role: %Role{stage: :review}}), do: &review_run_finished/2
  defp finish_action(%Run{role: %Role{stage: :qa}}), do: &qa_run_finished/2
  defp finish_action(%Run{role: %Role{stage: :demo}}), do: &demo_run_finished/2
  defp finish_action(%Run{}), do: fn run, _opts -> run end

  # A finish that recorded an error did not conclude anything, so it stays open
  # for the message that fixes it.
  defp latch_done(%Run{error: error} = run) when is_binary(error), do: run

  defp latch_done(%Run{} = run) do
    {:ok, latched} = run |> Run.changeset(%{stage_outcome: :done}) |> Repo.update()
    %{latched | task: run.task, role: run.role}
  end

  # This run is idle now, so whatever the human queued on it while it worked goes
  # out. A run parked on a question is not idle: the answer goes first.
  defp drain_queued_message(%Run{pending_chat: nil} = run, _opts), do: run

  defp drain_queued_message(%Run{} = run, opts) do
    if pending_questions(run.task_id) == [] do
      dispatch_message(run, opts)
    end

    run
  end
end
