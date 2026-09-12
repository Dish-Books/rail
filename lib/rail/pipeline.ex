defmodule Rail.Pipeline do
  @moduledoc """
  Context boundary for the Rail development pipeline.
  Coordinates tasks, stage transitions, questions, plans, queue ordering, and dispatching.
  """

  use Supervisor

  alias Rail.Pipeline.Actions

  @doc """
  Starts the processes this context owns: the runner that single-flights the
  actions in flight on each task.
  """
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Supervisor.init([Rail.Pipeline.TaskActionRunner], strategy: :one_for_one)
  end

  defdelegate settle_run(os_process, outcome \\ %{}, opts \\ []), to: Actions.SettleRun
  defdelegate run_finished(os_process, outcome \\ %{}, opts \\ []), to: Actions.RunFinished
  defdelegate parse_stage_verdict(run_or_id), to: Actions.ParseStageVerdict

  defdelegate approve_product_task(task), to: Actions.ApproveProductTask
  defdelegate start_product_run(task), to: Actions.StartProductRun
  defdelegate start_design_task(task), to: Actions.StartDesignTask

  defdelegate create_task(issue, stage), to: Actions.CreateTask
  defdelegate list_tasks(project_id, opts \\ []), to: Actions.ListTasks
  defdelegate update_task(task, attrs), to: Actions.UpdateTask
  defdelegate get_task(id), to: Actions.GetTask
  defdelegate get_plan(task), to: Actions.GetPlan
  defdelegate broadcast_pipeline_changed(meta \\ %{}), to: Actions.BroadcastPipelineChanged

  defdelegate recheck_design(task, opts \\ []), to: Actions.RecheckDesign
  defdelegate apply_design_manifest(task, opts \\ []), to: Actions.RecheckDesign
  defdelegate design_manifest_stamp(target), to: Actions.RecheckDesign
  defdelegate uses_design?(task, runs \\ []), to: Rail.Pipeline.Schemas.Task

  defdelegate decline_demo(task, note \\ nil), to: Actions.DeclineDemo
  defdelegate rerecord_demo(task, opts \\ []), to: Actions.RerecordDemo
  defdelegate can_rerecord_demo?(task), to: Actions.RerecordDemo
  defdelegate refresh_demo_freshness(task, opts \\ []), to: Actions.RefreshDemoFreshness

  defdelegate send_back_to_engineer(task, opts \\ []), to: Actions.SendBackToEngineer
  defdelegate skip_to_ready_to_merge(task), to: Actions.SkipToReadyToMerge
  defdelegate cancel_task(task, opts \\ []), to: Actions.CancelTask

  defdelegate register_question(run, question), to: Actions.RegisterQuestion
  defdelegate answer_questions(task, answers, opts \\ []), to: Actions.AnswerQuestions
  defdelegate dismiss_question(question), to: Actions.DismissQuestion
  defdelegate get_question(id), to: Actions.GetQuestion
  defdelegate list_questions(target \\ nil, opts \\ []), to: Actions.ListQuestions

  # TODO: lets change this to send_message(run, text) no opts, queue only for when agent is done
  # remove dispatch_chat_turn and maybe_dispatch_queued_pending_chat
  # remove stop_chat_turn and cancel_pending_chat we should instead have a generic stop_run
  # settle_chat_turn becomes a util and added to run_finished finish_action, it needs the same question handling as the others
  defdelegate send_chat_turn(task, role_id, text, opts \\ []), to: Actions.SendChatTurn
  defdelegate dispatch_chat_turn(task, role, run, opts \\ []), to: Actions.SendChatTurn
  defdelegate maybe_dispatch_queued_pending_chat(task, opts \\ []), to: Actions.SendChatTurn
  defdelegate stop_chat_turn(task), to: Actions.StopChatTurn
  defdelegate cancel_pending_chat(task, role_id), to: Actions.CancelPendingChat
  defdelegate settle_chat_turn(task_target, run_target, run_or_outcome \\ %{}, opts \\ []), to: Actions.SettleChatTurn

  defdelegate refresh_mergeability(task, opts \\ []), to: Actions.RefreshMergeability
  defdelegate mark_pr_ready(task, opts \\ []), to: Actions.MarkPrReady
  defdelegate start_rebase(task, opts \\ []), to: Actions.StartRebase
  defdelegate merge_task(task, opts \\ []), to: Actions.MergeTask
  defdelegate cleanup_task(task), to: Actions.CleanupTask

  defdelegate load_diff(task), to: Actions.LoadDiff
  defdelegate reconcile_viewed_diff_files(task, parsed_files), to: Actions.ReconcileViewedDiffFiles
  defdelegate set_diff_file_viewed(task, file_path, file_digest, viewed), to: Actions.SetDiffFileViewed
  defdelegate expand_diff_gap(task, file_path, gap_index, start_line, end_line, diff_rev), to: Actions.ExpandDiffGap
end
