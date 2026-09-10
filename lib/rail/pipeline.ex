defmodule Rail.Pipeline do
  @moduledoc """
  Context boundary for the Rail development pipeline.
  Coordinates tasks, stage transitions, questions, plans, queue ordering, and dispatching.
  """

  alias Rail.Pipeline.Actions
  alias Rail.Pipeline.Dispatcher
  alias Rail.Pipeline.Queue

  defdelegate bring_local(scope, issue), to: Actions.BringLocal
  defdelegate bring_local(scope, issue, owner_user), to: Actions.BringLocal
  defdelegate list_tasks(scope, project_id), to: Actions.ListTasks
  defdelegate list_tasks(scope, project_id, opts), to: Actions.ListTasks
  defdelegate get_task(scope, id), to: Actions.GetTask
  defdelegate get_task!(scope, id), to: Actions.GetTask
  defdelegate broadcast_pipeline_changed(), to: Actions.BroadcastPipelineChanged
  defdelegate broadcast_pipeline_changed(meta), to: Actions.BroadcastPipelineChanged
  defdelegate list_eligible_tasks(project_or_id, role), to: Queue, as: :eligible_tasks
  defdelegate pump_dispatcher, to: Dispatcher, as: :pump
  defdelegate dispatch_now(scope, task_or_id, opts), to: Actions.DispatchNow
  defdelegate dispatch_now(scope_or_task, task_or_opts), to: Actions.DispatchNow
  defdelegate dispatch_now(task_or_id), to: Actions.DispatchNow
  defdelegate dispatch_disabled?, to: Dispatcher
  defdelegate cancel_retry_timer(task_or_id), to: Dispatcher
  defdelegate arm_retry_timer(task_or_id), to: Dispatcher
  defdelegate retry_timers(), to: Dispatcher
  defdelegate rearm_pending_retries(), to: Dispatcher
  defdelegate start_stage_run(task, opts \\ []), to: Actions.StartStageRun
  defdelegate settle_run(task, role_run, run_or_outcome \\ %{}, opts \\ []), to: Actions.SettleRun
  defdelegate approve_stage(scope, task_or_id, opts), to: Actions.ApproveStage
  defdelegate approve_stage(scope_or_task, task_or_opts), to: Actions.ApproveStage
  defdelegate approve_stage(task_or_id), to: Actions.ApproveStage

  defdelegate request_changes(scope, task_or_id, comment, opts), to: Actions.RequestChanges
  defdelegate request_changes(scope_or_task, task_or_comment, comment_or_opts), to: Actions.RequestChanges
  defdelegate request_changes(task_or_id, comment), to: Actions.RequestChanges

  defdelegate send_back_to_engineer(scope, task_or_id, opts), to: Actions.SendBackToEngineer
  defdelegate send_back_to_engineer(scope_or_task, task_or_opts), to: Actions.SendBackToEngineer
  defdelegate send_back_to_engineer(task_or_id), to: Actions.SendBackToEngineer

  defdelegate skip_to_ready_to_merge(scope, task_or_id), to: Actions.SkipToReadyToMerge
  defdelegate skip_to_ready_to_merge(task_or_id), to: Actions.SkipToReadyToMerge

  defdelegate retry_stage(scope, task_or_id, opts), to: Actions.RetryStage
  defdelegate retry_stage(scope_or_task, task_or_opts), to: Actions.RetryStage
  defdelegate retry_stage(task_or_id), to: Actions.RetryStage

  defdelegate register_question(task_or_id, role_run_or_id, question_or_attrs, opts), to: Actions.RegisterQuestion
  defdelegate register_question(task_or_id, role_run_or_question, question_or_opts), to: Actions.RegisterQuestion
  defdelegate register_question(task_or_id, question_or_attrs), to: Actions.RegisterQuestion

  defdelegate answer_question(scope, question_or_id, answer_text), to: Actions.AnswerQuestion
  defdelegate answer_question(question_or_id, answer_text), to: Actions.AnswerQuestion

  defdelegate dismiss_question(scope, question_or_id), to: Actions.DismissQuestion
  defdelegate dismiss_question(question_or_id), to: Actions.DismissQuestion

  defdelegate release_blocked_stage(scope, task_or_id), to: Actions.ReleaseBlockedStage
  defdelegate release_blocked_stage(task_or_id), to: Actions.ReleaseBlockedStage

  defdelegate list_questions(scope, target_or_opts, opts), to: Actions.ListQuestions
  defdelegate list_questions(scope_or_target, target_or_opts), to: Actions.ListQuestions
  defdelegate list_questions(target_or_opts), to: Actions.ListQuestions
  defdelegate list_questions(), to: Actions.ListQuestions

  defdelegate get_question(scope, id), to: Actions.GetQuestion
  defdelegate get_question(id), to: Actions.GetQuestion
  defdelegate get_question!(scope, id), to: Actions.GetQuestion
  defdelegate get_question!(id), to: Actions.GetQuestion

  defdelegate list_pending_questions(scope, target, opts), to: Actions.ListQuestions
  defdelegate list_pending_questions(scope_or_target, target_or_opts), to: Actions.ListQuestions
  defdelegate list_pending_questions(target_or_opts), to: Actions.ListQuestions
  defdelegate list_pending_questions(), to: Actions.ListQuestions
end
