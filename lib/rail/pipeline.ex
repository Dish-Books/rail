defmodule Rail.Pipeline do
  @moduledoc """
  Context boundary for the Rail development pipeline.

  A task is created at `:plan`, where one agent writes the plan on the task's first
  round: a ticket, three design options when the change has a screen, and one
  implementation plan. The human picks an option, and one approval publishes the
  ticket and the picked design and marks the round approved. Engineer
  builds it and commits it, keeping the branch up to date with the default branch
  itself; Rail pushes the commits a turn leaves and, once CI passes, sends them to Review.

  Review is one run led by a Review lead, with the code reviewer, QA explorers, an
  engineer and a demo recorder as its subagents. A round reads the code and drives
  the running application, the demo is recorded beside it, and the findings land in
  one list for the human to rule on. The Review tray's Send has the engineer fix
  what was ruled Fix, and act on the sender's finding, diff and screen comments, inside
  Review and commit it, and the next round starts once CI passes on
  what the turn committed. A task never goes back to Engineer, and it waits at
  Review, ready to merge, once nothing is left to rule or fix.

  Plan can also end with a split: approval then makes each child an issue and a task of its own at
  Engineer, and parks the parent at Split until the last child merges.

  A finished review moves the task on to Finalize, which has no run of its own: a teammate marks it ready
  for a tech lead, a tech lead's Approve approves its pull request on GitHub as that lead, and a tech lead's
  Merge squash-merges it and enters Merged.
  """

  use Rail.PermissionsDecorator

  alias Rail.Pipeline.Actions

  defdelegate run_finished(os_process, outcome \\ %{}, opts \\ []), to: Actions.RunFinished

  defdelegate enter_stage(task, stage, opts \\ []), to: Actions.EnterStage

  defdelegate start_plan_run(issue_or_run), to: Actions.StartPlanRun
  @decorate can?(resource: :tasks, action: :approve)
  defdelegate approve_plan(scope, run), to: Actions.ApprovePlan

  defdelegate send_plan_to_lead(scope, run), to: Actions.SendPlanToLead
  defdelegate start_plan(scope, run), to: Actions.StartPlan
  defdelegate read_design(task, opts \\ []), to: Actions.ReadDesign
  defdelegate save_design_option(task, attrs), to: Actions.SaveDesignOption
  defdelegate pick_design_option(scope, run, key), to: Actions.PickDesignOption
  defdelegate read_plan(task), to: Actions.ReadPlan
  defdelegate save_plan(task, attrs), to: Actions.SavePlan
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
  defdelegate start_check_run(run), to: Actions.StartCheckRun
  defdelegate save_report(task, role, report), to: Actions.SaveReport
  defdelegate read_reports(task), to: Actions.ReadReports
  defdelegate save_finding(task, attrs), to: Actions.SaveFinding
  defdelegate list_findings(task), to: Actions.ListFindings
  defdelegate decide_finding(scope, finding, decision), to: Actions.DecideFinding
  defdelegate save_review(task), to: Actions.SaveReview
  defdelegate read_review(task), to: Actions.ReadReview
  defdelegate read_fix_plan(task), to: Actions.ReadFixPlan
  defdelegate save_fix_plan(task, attrs), to: Actions.SaveFixPlan
  defdelegate approve_fix_plan(scope, run, version), to: Actions.ApproveFixPlan
  defdelegate start_fix_round(scope, run), to: Actions.StartFixRound

  defdelegate create_round(task), to: Actions.CreateRound
  defdelegate list_rounds(task), to: Actions.ListRounds
  defdelegate save_round_plan(round, attrs), to: Actions.SaveRoundPlan

  defdelegate mark_ready(scope, task), to: Actions.MarkReady

  @decorate can?(resource: :tasks, action: :merge)
  defdelegate merge_task(scope, task), to: Actions.MergeTask

  @decorate can?(resource: :tasks, action: :approve)
  defdelegate approve_task(scope, task), to: Actions.ApproveTask

  defdelegate list_approvals(task), to: Actions.ListApprovals

  defdelegate write_qa_checklist(task, checks), to: Actions.WriteQaChecklist
  defdelegate read_qa_checklist(task), to: Actions.ReadQaChecklist
  defdelegate record_qa_check(task, key, outcome, note \\ nil), to: Actions.RecordQaCheck
  defdelegate get_finding_evidence(task, key, index), to: Actions.GetFindingEvidence

  defdelegate read_demo(task), to: Actions.ReadDemo

  defdelegate save_demo(task, attrs), to: Actions.SaveDemo
  defdelegate list_demo_beats(task), to: Actions.ListDemoBeats
  defdelegate record_demo(scope, task), to: Actions.RecordDemo
  defdelegate check_base(task), to: Actions.CheckBase
  defdelegate update_branch(scope, task), to: Actions.UpdateBranch
  defdelegate save_screen(task, attrs), to: Actions.SaveScreen
  defdelegate list_screens(task), to: Actions.ListScreens

  defdelegate start_task(issue, stage), to: Actions.StartTask
  defdelegate create_task(issue, stage), to: Actions.CreateTask
  defdelegate list_tasks(opts \\ []), to: Actions.ListTasks
  defdelegate update_task(task, attrs), to: Actions.UpdateTask
  defdelegate get_task(id), to: Actions.GetTask
  defdelegate cleanup_task(task), to: Actions.CleanupTask
  defdelegate discard_task(task), to: Actions.DiscardTask

  defdelegate ask_questions(run, questions), to: Actions.AskQuestions
  defdelegate answer_question(scope, question, answer), to: Actions.AnswerQuestion
  defdelegate send_answers(scope, run), to: Actions.SendAnswers
  defdelegate dismiss_round(run), to: Actions.DismissRound
  defdelegate dismiss_question(question), to: Actions.DismissQuestion
  defdelegate get_question(id), to: Actions.GetQuestion
  defdelegate list_questions(task, opts \\ []), to: Actions.ListQuestions

  defdelegate send_message(scope, run, text, opts \\ []), to: Actions.SendMessage
  defdelegate create_diff_comment(scope, task, attrs), to: Actions.CreateDiffComment
  defdelegate list_diff_comments(scope, task, opts \\ []), to: Actions.ListDiffComments
  defdelegate delete_diff_comment(scope, comment), to: Actions.DeleteDiffComment
  defdelegate set_diff_comment_resolved(scope, comment, resolved?), to: Actions.SetDiffCommentResolved
  defdelegate create_screen_comment(scope, task, attrs), to: Actions.CreateScreenComment
  defdelegate list_screen_comments(scope, task), to: Actions.ListScreenComments
  defdelegate delete_screen_comment(scope, comment), to: Actions.DeleteScreenComment
  defdelegate create_finding_comment(scope, task, attrs), to: Actions.CreateFindingComment
  defdelegate list_finding_comments(scope, task), to: Actions.ListFindingComments
  defdelegate delete_finding_comment(scope, comment), to: Actions.DeleteFindingComment
  defdelegate create_plan_comment(scope, run, attrs), to: Actions.CreatePlanComment
  defdelegate list_plan_comments(scope, task), to: Actions.ListPlanComments
  defdelegate delete_plan_comment(scope, comment), to: Actions.DeletePlanComment
  defdelegate send_plan_comments(scope, run), to: Actions.SendPlanComments
  defdelegate stop_and_send_message(scope, run, opts \\ []), to: Actions.StopAndSendMessage
  defdelegate stop_run(scope, run, opts \\ []), to: Actions.StopRun

  defdelegate start_or_resume_run(task, role, worktree_path, opts \\ []), to: Actions.StartOrResumeRun
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
