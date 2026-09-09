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
end
