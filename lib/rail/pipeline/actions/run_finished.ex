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
  does, when what it concluded leaves nobody anything to decide. The Review lead
  is the exception: each message reopens its latch, and each turn that ends with
  its review saved earns it again.
  """

  import Rail.Pipeline.Utils.BroadcastPipelineChanged
  import Rail.Pipeline.Utils.CiRunFinished
  import Rail.Pipeline.Utils.DispatchMessage
  import Rail.Pipeline.Utils.EngineerRunFinished
  import Rail.Pipeline.Utils.PlanRunFinished
  import Rail.Pipeline.Utils.QuestionQueue
  import Rail.Pipeline.Utils.RegisterAskedQuestions
  import Rail.Pipeline.Utils.ReviewRunFinished
  import Rail.Pipeline.Utils.SetupRunFinished
  import Rail.Pipeline.Utils.UnsentRound

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Settles the run whose OS process just exited, against `outcome`.
  """
  def run_finished(%OsProcess{} = os_process, outcome \\ %{}, opts \\ []) do
    case Repo.preload(os_process, [run: [:task, :role]], force: true) do
      %OsProcess{run: %Run{task: %Task{}}} = os_process ->
        run =
          os_process
          |> settle_run(outcome)
          |> end_turn(os_process)
          |> finish(os_process, opts)
          |> drain_queued_message(opts)
          |> send_rail_answers(os_process)
          |> broadcast_pipeline_changed()

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

    status = settled_status(run)

    # A run resumed after asking ends with this turn, not the one that asked.
    completed_at =
      if status == :blocked_on_input, do: run.completed_at || DateTime.utc_now(), else: DateTime.utc_now()

    attrs = %{
      status: status,
      completed_at: completed_at,
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

  # Rail sends on only what the agents that commit to the branch committed, so work left uncommitted is said.
  defp end_turn(%Run{role: %Role{stage: stage}, task: %Task{} = task} = run, %OsProcess{kind: :agent})
       when stage in [:engineer, :review_lead] do
    if Task.worktree_present?(task) and Git.worktree_dirty?(task.worktree_path) do
      Pipeline.append_run_events(run.id, nil, [
        "[rail] This turn left uncommitted changes in the worktree. Rail sends on only what is committed, so they wait for the next turn to commit them."
      ])
    end

    run
  end

  defp end_turn(%Run{} = run, %OsProcess{}), do: run

  # A setup script asks no questions and concludes nothing about its stage.
  defp finish(%Run{} = run, %OsProcess{kind: :setup}, opts), do: setup_run_finished(run, opts)
  defp finish(%Run{} = run, %OsProcess{kind: :ci} = os_process, _opts), do: ci_run_finished(run, os_process)

  defp finish(%Run{} = run, %OsProcess{} = os_process, opts) do
    case register_asked_questions(os_process, run) do
      [] -> maybe_finish(run, opts)
      _asked -> run
    end
  end

  # A finish with nothing to conclude yet, such as an engineer turn that committed nothing, leaves the stage open.
  defp maybe_finish(%Run{} = run, opts) do
    if concluded?(run) do
      case apply_finish(run, opts) do
        {:open, open} -> open
        finished -> latch_done(finished)
      end
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

  # The Review lead has its say at the end of every round, so a turn after one it already latched counts too.
  defp concluded?(%Run{role: %Role{stage: :review_lead}} = run) do
    run.exit_code == 0 and not asked_anything_open?(run)
  end

  # Every other run only concludes by saying so, having actually finished: a
  # non-zero exit and a run still parked on a question are both runs that have
  # not.
  defp concluded?(%Run{} = run) do
    run.stage_outcome == :in_progress and
      run.exit_code == 0 and
      not asked_anything_open?(run)
  end

  # Only this run's own questions hold its finish: one another stage left open is
  # that stage's to settle.
  defp asked_anything_open?(%Run{id: run_id, task_id: task_id}) do
    Enum.any?(pending_questions(task_id), &(&1.run_id == run_id))
  end

  defp finish_action(%Run{role: %Role{stage: :plan}}), do: &plan_run_finished/2
  defp finish_action(%Run{role: %Role{stage: :engineer}}), do: &engineer_run_finished/2
  defp finish_action(%Run{role: %Role{stage: :review_lead}}), do: &review_run_finished/2

  defp finish_action(%Run{}), do: fn run, _opts -> run end

  # A finish that recorded an error did not conclude anything, so it stays open
  # for the message that fixes it, and one that started CI is settled by CI's finish.
  defp latch_done(%Run{error: error} = run) when is_binary(error), do: run

  defp latch_done(%Run{status: status} = run) when status in [:running, :waiting_for_resources, :waiting_for_usage],
    do: run

  defp latch_done(%Run{} = run) do
    {:ok, latched} = run |> Run.changeset(%{stage_outcome: :done}) |> Repo.update()
    %{latched | task: run.task, role: run.role}
  end

  # A round Rail answered whole from past answers waits on nobody, so it goes back at
  # once; one a person still has to answer waits, as does one whose turn was stopped.
  defp send_rail_answers(%Run{} = run, %OsProcess{ended_reason: reason}) when reason in [:stopped, :handed_over], do: run

  defp send_rail_answers(%Run{} = run, %OsProcess{}) do
    round = unsent_round(run)

    if round != [] and Enum.all?(round, &(&1.status == :answered and &1.answered_by_rail)) do
      _sent = Pipeline.send_answers(Scope.for_system(), run)
      %{Repo.get!(Run, run.id) | task: run.task, role: run.role}
    else
      run
    end
  end

  # This run is idle now, so whatever the human queued on it while it worked goes
  # out. A run parked on a question is not idle: the answer goes first.
  defp drain_queued_message(%Run{pending_chat: nil} = run, _opts), do: run

  # Finishing started another process on this run, running or in line, and the
  # message waits for it.
  defp drain_queued_message(%Run{status: status} = run, _opts)
       when status in [:running, :waiting_for_resources, :waiting_for_usage], do: run

  defp drain_queued_message(%Run{} = run, opts) do
    if pending_questions(run.task_id) == [] do
      dispatch_message(run, opts)
    end

    run
  end
end
