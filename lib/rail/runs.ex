defmodule Rail.Runs do
  @moduledoc """
  Context for agent CLI execution, argv/prompt building, process spawning,
  stream following, and run lifecycle management.
  """

  alias Rail.Runs.Actions

  # Argv and prompt building

  defdelegate append_pending_answer(run, answer, opts \\ []), to: Actions.AppendPendingAnswer
  defdelegate build_args(opts), to: Actions.BuildArgs
  defdelegate build_prompt(opts), to: Actions.BuildPrompt
  defdelegate chat_prompt(message), to: Actions.ChatPrompt
  defdelegate detect_question(line, opts \\ []), to: Actions.DetectQuestion
  defdelegate detect_questions(line, opts \\ []), to: Actions.DetectQuestion

  # Process lifecycle and execution

  defdelegate start_os_process(run, argv, opts \\ []), to: Actions.StartOsProcess
  defdelegate stop_os_process(os_process_or_run_or_task_id, opts \\ []), to: Actions.StopOsProcess
  defdelegate running?(task_id), to: Actions.Running
  defdelegate is_running?(task_id), to: Actions.Running, as: :running?

  # Persistence and query helpers

  defdelegate start_or_resume_run(task, role, worktree_path), to: Actions.StartOrResumeRun
  defdelegate create_run(attrs), to: Actions.CreateRun
  defdelegate get_run(id), to: Actions.GetRun
  defdelegate update_run(run, attrs), to: Actions.UpdateRun
  defdelegate get_os_process(id), to: Actions.GetOsProcess
  defdelegate list_os_processes(opts \\ []), to: Actions.ListOsProcesses
  defdelegate list_run_events(run_id, opts \\ []), to: Actions.ListRunEvents
  defdelegate append_run_event(run_or_id, line), to: Actions.AppendRunEvent
end
