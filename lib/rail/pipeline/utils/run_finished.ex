defmodule Rail.Pipeline.Utils.RunFinished do
  @moduledoc """
  The one thing that happens when an OS process exits.

  The run layer calls this from the process's own row, so it works the same whether
  the Follower saw the exit or `Rail.Runs.Boot` found the process already gone after
  a restart. Nothing is wired in at spawn time: everything this needs — the task, the
  run, whether the process was a chat turn — is on the row.

  In order: a chat turn settles as a chat turn and the stage is left alone. Otherwise
  the run is recorded, and then the agent's own words for this process are read back
  and any questions in them are filed. A run that asked something parks on it and stops
  here — the answer, not this exit, moves it on. Only a clean run that asked nothing
  reaches its stage.
  """

  import Rail.Pipeline.Utils.ArchitectRunFinished
  import Rail.Pipeline.Utils.DemoRunFinished
  import Rail.Pipeline.Utils.DesignRunFinished
  import Rail.Pipeline.Utils.EngineerRunFinished
  import Rail.Pipeline.Utils.ProductRunFinished
  import Rail.Pipeline.Utils.QaLeadRunFinished
  import Rail.Pipeline.Utils.QaRunFinished
  import Rail.Pipeline.Utils.RebaseRunFinished
  import Rail.Pipeline.Utils.RegisterAskedQuestions
  import Rail.Pipeline.Utils.ReviewRunFinished

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run

  @doc """
  Settles the OS process that just exited, against `outcome`.
  """
  def run_finished(%OsProcess{} = os_process, outcome \\ %{}, opts \\ []) do
    case Repo.preload(os_process, [run: :task], force: true) do
      %OsProcess{is_chat: true, run: %Run{task: %Task{} = task} = run} ->
        Pipeline.settle_chat_turn(task, run, outcome, opts)

      %OsProcess{run: %Run{task: %Task{}}} = stage_process ->
        settle_stage(stage_process, outcome, opts)

      _unresolved ->
        {:error, :invalid_state}
    end
  end

  defp settle_stage(%OsProcess{} = os_process, outcome, opts) do
    # TODO: inline settle_run which should just return a run with the right preloads so
    # register_asked_questions doesn't need to, maybe even on the os_process at the beginning of this file
    with {:ok, %Task{} = task, %Run{} = run} <- Pipeline.settle_run(os_process, outcome, opts) do
      case register_asked_questions(os_process, run) do
        [] -> finish_action(task).(os_process, outcome, opts)
        _asked -> {:ok, task, run}
      end
    end
  end

  # The one place left that matches on `task.stage`: everything downstream of it is
  # per-stage by construction, and no two stages share a finish.
  defp finish_action(%Task{is_rebasing: true}), do: &finish_rebase_run/3
  defp finish_action(%Task{stage: :product}), do: &finish_product_run/3
  defp finish_action(%Task{stage: :design}), do: &finish_design_run/3
  defp finish_action(%Task{stage: :architect}), do: &finish_architect_run/3
  defp finish_action(%Task{stage: :engineer}), do: &finish_engineer_run/3
  defp finish_action(%Task{stage: :review}), do: &finish_review_run/3
  defp finish_action(%Task{stage: :qa}), do: &finish_qa_run/3
  defp finish_action(%Task{stage: :qa_lead}), do: &finish_qa_lead_run/3
  defp finish_action(%Task{stage: :demo}), do: &finish_demo_run/3
end
