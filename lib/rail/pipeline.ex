defmodule Rail.Pipeline do
  @moduledoc """
  Context boundary for the Rail development pipeline.

  A task is created at `:plan`, where one run leads Product, Designer and
  Architect as subagents to a ticket, three design options when the change has a
  screen, and one implementation plan. The human picks an option, and one approval
  publishes the ticket and the picked design and records the plan. Engineer
  builds it: Rail commits and pushes what it leaves, and the human reads the diff
  and sends it to review. Review reads the change and raises findings, each with a
  recommendation; the human decides which to address and either sends them back to
  the engineer or hands the change to QA. QA drives the running application and
  reports the same way, with a verdict over the top of it, and what the human
  sends back from there goes to the engineer and comes round through review
  again before QA sees it a second time. A task past Engineer whose code changes
  goes back there, and has to come through review and QA again.

  Demo drives the same application QA did, for the opposite reason: it records a
  walkthrough of the change working, narrated a beat at a time, for somebody who
  will watch two minutes of video and open nothing else. It is where a task
  stops: nothing moves it on from there yet.

  Plan can also end with a split: approval then makes each child an issue and a task of its own at
  Engineer, and parks the parent at Split until the last child merges.

  Merge is a stage a task can reach and nothing drives or reaches: a task put
  there parks there.
  """

  alias Rail.Pipeline.Actions

  defdelegate run_finished(os_process, outcome \\ %{}, opts \\ []), to: Actions.RunFinished

  defdelegate enter_stage(task, stage, opts \\ []), to: Actions.EnterStage

  defdelegate start_plan_run(issue_or_run), to: Actions.StartPlanRun
  defdelegate approve_plan(scope, run), to: Actions.ApprovePlan
  defdelegate read_ticket(task), to: Actions.ReadTicket
  defdelegate save_ticket(task, attrs), to: Actions.SaveTicket
  defdelegate read_design(task, opts \\ []), to: Actions.ReadDesign
  defdelegate save_design_option(task, attrs), to: Actions.SaveDesignOption
  defdelegate pick_design_option(scope, run, key), to: Actions.PickDesignOption
  defdelegate read_plan(task), to: Actions.ReadPlan
  defdelegate save_plan(task, attrs), to: Actions.SavePlan
  defdelegate get_implementation_plan(task), to: Actions.GetImplementationPlan
  defdelegate read_split(task), to: Actions.ReadSplit
  defdelegate save_split(task, attrs), to: Actions.SaveSplit
  defdelegate create_child_task(parent, issue, child), to: Actions.CreateChildTask
  defdelegate handle_issue_finished(issue), to: Actions.HandleIssueFinished

  defdelegate start_engineer_run(run), to: Actions.StartEngineerRun
  defdelegate end_turn_and_commit(task, os_process, message), to: Actions.EndTurnAndCommit
  defdelegate end_turn_and_merge(task, os_process), to: Actions.EndTurnAndMerge
  defdelegate commit_engineer_work(scope, task, message), to: Actions.CommitEngineerWork
  defdelegate commit_and_send_to_review(scope, run), to: Actions.CommitAndSendToReview
  defdelegate send_to_review(run), to: Actions.SendToReview
  defdelegate changed_since_review?(task), to: Actions.ChangedSinceReview
  defdelegate run_ci(scope, run), to: Actions.RunCi
  defdelegate update_branch(scope, task), to: Actions.UpdateBranch
  defdelegate get_ci_status(run), to: Actions.GetCiStatus

  defdelegate start_review_run(run), to: Actions.StartReviewRun
  defdelegate read_review(task), to: Actions.ReadReview
  defdelegate save_review_finding(task, attrs), to: Actions.SaveReviewFinding
  defdelegate save_review(task), to: Actions.SaveReview
  defdelegate list_review_findings(task), to: Actions.ListReviewFindings
  defdelegate decide_review_finding(scope, finding, decision), to: Actions.DecideReviewFinding
  defdelegate send_findings_to_engineer(run), to: Actions.SendFindingsToEngineer
  defdelegate send_to_qa(run), to: Actions.SendToQa

  defdelegate start_qa_run(run), to: Actions.StartQaRun
  defdelegate write_qa_checklist(task, checks), to: Actions.WriteQaChecklist
  defdelegate read_qa_checklist(task), to: Actions.ReadQaChecklist
  defdelegate record_qa_check(task, key, outcome, note \\ nil), to: Actions.RecordQaCheck
  defdelegate list_qa_evidence(task), to: Actions.ListQaEvidence
  defdelegate read_qa_evidence(task, evidence), to: Actions.ReadQaEvidence
  defdelegate classify_qa_evidence(task, path), to: Actions.ClassifyQaEvidence
  defdelegate read_qa_report(task), to: Actions.ReadQaReport
  defdelegate save_qa_finding(task, attrs), to: Actions.SaveQaFinding
  defdelegate save_qa_verdict(task, attrs), to: Actions.SaveQaVerdict
  defdelegate list_qa_findings(task), to: Actions.ListQaFindings
  defdelegate decide_qa_finding(scope, finding, decision), to: Actions.DecideQaFinding
  defdelegate send_qa_findings_to_engineer(run), to: Actions.SendQaFindingsToEngineer
  defdelegate send_to_demo(run), to: Actions.SendToDemo
  defdelegate record_demo(scope, task), to: Actions.RecordDemo
  defdelegate skip_demo(scope, task), to: Actions.SkipDemo

  defdelegate start_demo_run(run), to: Actions.StartDemoRun
  defdelegate read_demo(task), to: Actions.ReadDemo
  defdelegate save_demo(task, attrs), to: Actions.SaveDemo
  defdelegate list_demo_beats(task), to: Actions.ListDemoBeats

  defdelegate start_task(issue, stage), to: Actions.StartTask
  defdelegate create_task(issue, stage), to: Actions.CreateTask
  defdelegate list_tasks(opts \\ []), to: Actions.ListTasks
  defdelegate update_task(task, attrs), to: Actions.UpdateTask
  defdelegate get_task(id), to: Actions.GetTask
  defdelegate cleanup_task(task), to: Actions.CleanupTask

  defdelegate register_question(run, question), to: Actions.RegisterQuestion
  defdelegate answer_question(scope, question, answer), to: Actions.AnswerQuestion
  defdelegate send_answers(scope, run), to: Actions.SendAnswers
  defdelegate dismiss_round(run), to: Actions.DismissRound
  defdelegate dismiss_question(question), to: Actions.DismissQuestion
  defdelegate get_question(id), to: Actions.GetQuestion
  defdelegate list_questions(task, opts \\ []), to: Actions.ListQuestions

  defdelegate send_message(scope, run, text, opts \\ []), to: Actions.SendMessage
  defdelegate create_diff_comment(scope, task, attrs), to: Actions.CreateDiffComment
  defdelegate list_diff_comments(scope, task), to: Actions.ListDiffComments
  defdelegate delete_diff_comment(scope, comment), to: Actions.DeleteDiffComment
  defdelegate send_diff_comments(scope, run), to: Actions.SendDiffComments
  defdelegate set_diff_comment_resolved(scope, comment, resolved?), to: Actions.SetDiffCommentResolved
  defdelegate stop_and_send_message(scope, run, opts \\ []), to: Actions.StopAndSendMessage
  defdelegate stop_run(scope, run, opts \\ []), to: Actions.StopRun

  defdelegate start_or_resume_run(task, role, worktree_path), to: Actions.StartOrResumeRun
  defdelegate create_run(attrs), to: Actions.CreateRun
  defdelegate get_run(id), to: Actions.GetRun
  defdelegate list_runs(opts \\ []), to: Actions.ListRuns
  defdelegate count_attention(opts \\ []), to: Actions.CountAttention
  defdelegate update_run(run, attrs), to: Actions.UpdateRun

  defdelegate append_run_events(run_id, os_process_id, lines), to: Actions.AppendRunEvents
  defdelegate broadcast_output_saved(task), to: Actions.BroadcastOutputSaved
  defdelegate list_run_events(run, opts \\ []), to: Actions.ListRunEvents
  defdelegate parse_transcript(lines), to: Actions.ParseTranscript

  defdelegate build_prompt(opts), to: Actions.BuildPrompt
end
