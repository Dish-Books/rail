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
  defdelegate dispatch_now(task_or_id), to: Dispatcher
  defdelegate dispatch_disabled?, to: Dispatcher
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

  defdelegate retry_stage(scope, task_or_id), to: Actions.RetryStage
  defdelegate retry_stage(task_or_id), to: Actions.RetryStage
end
