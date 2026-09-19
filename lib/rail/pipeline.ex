defmodule Rail.Pipeline do
  @moduledoc """
  Context boundary for the Rail development pipeline.

  A task is created at `:product`, its run is started, the human approves the
  ticket it writes, and the task is handed to design, where the human picks one of
  three options, refines it in chat and approves it. Architect turns that into one
  implementation plan, which the human approves in the same way, and engineer
  builds it — Rail commits and pushes what it leaves, and the human reads the diff
  and sends it to review. Review reads the change and raises findings, each with a
  recommendation; the human decides which to address and either sends them back to
  the engineer or hands the change to QA. QA drives the running application and
  reports the same way, with a verdict over the top of it, and what the human
  sends back from there goes to the engineer and comes round through review
  again before QA sees it a second time.

  Demo and merge are stages a task can reach and nothing drives yet: a task
  entering one parks there.
  """

  alias Rail.Pipeline.Actions

  defdelegate run_finished(os_process, outcome \\ %{}, opts \\ []), to: Actions.RunFinished

  defdelegate enter_stage(task, stage, opts \\ []), to: Actions.EnterStage

  defdelegate start_product_run(issue), to: Actions.StartProductRun
  defdelegate approve_product_plan(run, opts \\ []), to: Actions.ApproveProductPlan
  defdelegate read_ticket(task), to: Actions.ReadTicket

  defdelegate start_design_run(run), to: Actions.StartDesignRun
  defdelegate read_design(task), to: Actions.ReadDesign
  defdelegate pick_design_option(run, key), to: Actions.PickDesignOption
  defdelegate approve_design(run), to: Actions.ApproveDesign

  defdelegate start_architect_run(run), to: Actions.StartArchitectRun
  defdelegate read_plan(task), to: Actions.ReadPlan
  defdelegate approve_plan(run), to: Actions.ApprovePlan
  defdelegate get_implementation_plan(task), to: Actions.GetImplementationPlan

  defdelegate start_engineer_run(run), to: Actions.StartEngineerRun
  defdelegate read_commit_message(task), to: Actions.ReadCommitMessage
  defdelegate commit_engineer_work(scope, task), to: Actions.CommitEngineerWork
  defdelegate send_to_review(run), to: Actions.SendToReview

  defdelegate start_review_run(run), to: Actions.StartReviewRun
  defdelegate read_review(task), to: Actions.ReadReview
  defdelegate sync_review_findings(task, findings), to: Actions.SyncReviewFindings
  defdelegate list_review_findings(task), to: Actions.ListReviewFindings
  defdelegate decide_review_finding(finding, decision), to: Actions.DecideReviewFinding
  defdelegate send_findings_to_engineer(run), to: Actions.SendFindingsToEngineer
  defdelegate send_to_qa(run), to: Actions.SendToQa

  defdelegate start_qa_run(run), to: Actions.StartQaRun
  defdelegate write_qa_checklist(task, checks), to: Actions.WriteQaChecklist
  defdelegate read_qa_checklist(task), to: Actions.ReadQaChecklist
  defdelegate record_qa_check(task, key, outcome, note \\ nil), to: Actions.RecordQaCheck
  defdelegate list_qa_evidence(task), to: Actions.ListQaEvidence
  defdelegate read_qa_report(task), to: Actions.ReadQaReport
  defdelegate sync_qa_findings(task, findings), to: Actions.SyncQaFindings
  defdelegate list_qa_findings(task), to: Actions.ListQaFindings
  defdelegate decide_qa_finding(finding, decision), to: Actions.DecideQaFinding
  defdelegate send_qa_findings_to_engineer(run), to: Actions.SendQaFindingsToEngineer
  defdelegate send_to_demo(run), to: Actions.SendToDemo

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
