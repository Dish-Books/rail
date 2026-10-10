defmodule Rail.Pipeline do
  @moduledoc """
  Context boundary for the Rail development pipeline.

  A task is created at `:plan`, where one run leads Product, Designer and
  Architect as subagents to a ticket, three design options when the change has a
  screen, and one implementation plan. The human picks an option, and one approval
  publishes the ticket and the picked design and records the plan. Engineer
  builds it and commits it, keeping the branch up to date with the default branch
  itself; Rail pushes the commits a turn leaves and, once CI passes, sends them to Review.

  Review is one run led by a Review lead, with the code reviewer, QA explorers, an
  engineer and a demo recorder as its subagents. A round reads the code and drives
  the running application, the demo is recorded beside it, and the findings land in
  one list for the human to rule on. Start fix round has the engineer fix what was
  ruled Fix inside Review and commit it, and the next round starts once CI passes on
  what the turn committed. A task never goes back to Engineer, and it waits at
  Review, ready to merge, once nothing is left to rule or fix.

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
  defdelegate share_owner_with_children(issue), to: Actions.ShareOwnerWithChildren

  defdelegate start_engineer_run(run), to: Actions.StartEngineerRun
  defdelegate hand_over_work(scope, run), to: Actions.HandOverWork
  defdelegate send_to_review(run), to: Actions.SendToReview
  defdelegate run_ci(scope, run), to: Actions.RunCi
  defdelegate get_ci_status(run), to: Actions.GetCiStatus

  defdelegate start_review_run(run), to: Actions.StartReviewRun
  defdelegate save_finding(task, attrs), to: Actions.SaveFinding
  defdelegate list_findings(task), to: Actions.ListFindings
  defdelegate decide_finding(scope, finding, decision), to: Actions.DecideFinding
  defdelegate save_review(task), to: Actions.SaveReview
  defdelegate read_review(task), to: Actions.ReadReview
  defdelegate start_fix_round(run), to: Actions.StartFixRound

  defdelegate write_qa_checklist(task, checks), to: Actions.WriteQaChecklist
  defdelegate read_qa_checklist(task), to: Actions.ReadQaChecklist
  defdelegate record_qa_check(task, key, outcome, note \\ nil), to: Actions.RecordQaCheck
  defdelegate get_finding_evidence(task, key, index), to: Actions.GetFindingEvidence

  defdelegate read_demo(task), to: Actions.ReadDemo

  defdelegate save_demo(task, attrs), to: Actions.SaveDemo
  defdelegate list_demo_beats(task), to: Actions.ListDemoBeats
  defdelegate record_demo(scope, task), to: Actions.RecordDemo
  defdelegate save_screen(task, attrs), to: Actions.SaveScreen
  defdelegate list_screens(task), to: Actions.ListScreens

  defdelegate start_task(issue, stage), to: Actions.StartTask
  defdelegate create_task(issue, stage), to: Actions.CreateTask
  defdelegate list_tasks(opts \\ []), to: Actions.ListTasks
  defdelegate update_task(task, attrs), to: Actions.UpdateTask
  defdelegate get_task(id), to: Actions.GetTask
  defdelegate cleanup_task(task), to: Actions.CleanupTask
  defdelegate discard_task(task), to: Actions.DiscardTask

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
  defdelegate create_plan_comment(scope, run, attrs), to: Actions.CreatePlanComment
  defdelegate list_plan_comments(scope, task), to: Actions.ListPlanComments
  defdelegate delete_plan_comment(scope, comment), to: Actions.DeletePlanComment
  defdelegate send_plan_comments(scope, run), to: Actions.SendPlanComments
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
