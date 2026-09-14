defmodule Rail.Pipeline do
  @moduledoc """
  Context boundary for the Rail development pipeline.

  Product and design are driven today: a task is created at `:product`, its run
  is started, the human approves the ticket it writes, and the task is handed to
  design, where the human picks one of three options, refines it in chat and
  approves it. Everything past that hand-off (architect, engineer, review, QA,
  demo, rebase and merge) lives in `old/` until it is built back.
  """

  alias Rail.Pipeline.Actions

  defdelegate run_finished(os_process, outcome \\ %{}, opts \\ []), to: Actions.RunFinished

  defdelegate enter_stage(task, stage, opts \\ []), to: Actions.EnterStage

  defdelegate start_product_run(issue), to: Actions.StartProductRun
  defdelegate approve_product_plan(run, opts \\ []), to: Actions.ApproveProductPlan
  defdelegate read_ticket(task), to: Actions.ReadTicket

  defdelegate start_design_run(task, role, run, worktree_path), to: Actions.StartDesignRun
  defdelegate read_design(task), to: Actions.ReadDesign
  defdelegate pick_design_option(run, key), to: Actions.PickDesignOption
  defdelegate approve_design(run), to: Actions.ApproveDesign

  defdelegate create_task(issue, stage), to: Actions.CreateTask
  defdelegate list_tasks(opts \\ []), to: Actions.ListTasks
  defdelegate update_task(task, attrs), to: Actions.UpdateTask
  defdelegate get_task(id), to: Actions.GetTask
  defdelegate cleanup_task(task), to: Actions.CleanupTask

  defdelegate register_question(run, question), to: Actions.RegisterQuestion
  defdelegate answer_question(question, answer), to: Actions.AnswerQuestion
  defdelegate send_answers(run), to: Actions.SendAnswers
  defdelegate dismiss_question(question), to: Actions.DismissQuestion
  defdelegate get_question(id), to: Actions.GetQuestion
  defdelegate list_questions(task, opts \\ []), to: Actions.ListQuestions

  defdelegate send_message(run, text), to: Actions.SendMessage
  defdelegate stop_and_send_message(run, opts \\ []), to: Actions.StopAndSendMessage
  defdelegate stop_run(run, opts \\ []), to: Actions.StopRun

  defdelegate start_or_resume_run(task, role, worktree_path), to: Actions.StartOrResumeRun
  defdelegate create_run(attrs), to: Actions.CreateRun
  defdelegate get_run(id), to: Actions.GetRun
  defdelegate list_runs(opts \\ []), to: Actions.ListRuns
  defdelegate update_run(run, attrs), to: Actions.UpdateRun

  defdelegate append_run_events(run_id, os_process_id, lines), to: Actions.AppendRunEvents
  defdelegate list_run_events(run, opts \\ []), to: Actions.ListRunEvents
  defdelegate parse_transcript(lines), to: Actions.ParseTranscript

  defdelegate build_prompt(opts), to: Actions.BuildPrompt
end
