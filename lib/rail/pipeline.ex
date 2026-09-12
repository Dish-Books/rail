defmodule Rail.Pipeline do
  @moduledoc """
  Context boundary for the Rail development pipeline.
  Coordinates tasks, stage transitions, questions, plans, queue ordering, and dispatching.
  """

  alias Rail.Pipeline.Actions
  alias Rail.Pipeline.Utils

  defdelegate settle_run(os_process, outcome \\ %{}, opts \\ []), to: Actions.SettleRun
  defdelegate run_finished(os_process, outcome \\ %{}, opts \\ []), to: Utils.RunFinished
  defdelegate send_run_message(run, text, opts \\ []), to: Utils.SendRunMessage

  defdelegate settle_product_run(os_process, outcome \\ %{}, opts \\ []), to: Actions.SettleProductRun
  defdelegate settle_design_run(os_process, outcome \\ %{}, opts \\ []), to: Actions.SettleDesignRun
  defdelegate settle_architect_run(os_process, outcome \\ %{}, opts \\ []), to: Actions.SettleArchitectRun
  defdelegate settle_engineer_run(os_process, outcome \\ %{}, opts \\ []), to: Actions.SettleEngineerRun
  defdelegate settle_review_run(os_process, outcome \\ %{}, opts \\ []), to: Actions.SettleReviewRun
  defdelegate settle_qa_run(os_process, outcome \\ %{}, opts \\ []), to: Actions.SettleQaRun
  defdelegate settle_qa_lead_run(os_process, outcome \\ %{}, opts \\ []), to: Actions.SettleQaLeadRun
  defdelegate settle_demo_run(os_process, outcome \\ %{}, opts \\ []), to: Actions.SettleDemoRun
  defdelegate settle_rebase_run(os_process, outcome \\ %{}, opts \\ []), to: Actions.SettleRebaseRun

  defdelegate parse_stage_verdict(run_or_id), to: Actions.ParseStageVerdict

  defdelegate approve_product_task(task), to: Actions.ApproveProductTask
  defdelegate start_product_run(task), to: Actions.StartProductRun
  defdelegate start_design_task(task), to: Actions.StartDesignTask

  defdelegate create_task(issue, stage), to: Actions.CreateTask
  defdelegate list_tasks(scope, project_id), to: Actions.ListTasks
  defdelegate list_tasks(scope, project_id, opts), to: Actions.ListTasks
  defdelegate update_task(scope, task_or_id, attrs), to: Actions.UpdateTask
  defdelegate get_task(scope, id), to: Actions.GetTask
  defdelegate get_task!(scope, id), to: Actions.GetTask
  defdelegate get_plan(scope, task_or_id), to: Actions.GetPlan
  defdelegate get_plan(task_or_id), to: Actions.GetPlan
  defdelegate broadcast_pipeline_changed(meta \\ %{}), to: Actions.BroadcastPipelineChanged

  defdelegate approve_stage(scope, task_or_id, opts), to: Actions.ApproveStage
  defdelegate approve_stage(scope_or_task, task_or_opts), to: Actions.ApproveStage
  defdelegate approve_stage(task_or_id), to: Actions.ApproveStage

  defdelegate request_changes(scope, task_or_id, comment, opts), to: Actions.RequestChanges
  defdelegate request_changes(scope_or_task, task_or_comment, comment_or_opts), to: Actions.RequestChanges
  defdelegate request_changes(task_or_id, comment), to: Actions.RequestChanges

  defdelegate pick_design_direction(scope, task_or_id, key, opts), to: Actions.PickDesignDirection
  defdelegate pick_design_direction(a, b, c), to: Actions.PickDesignDirection
  defdelegate pick_design_direction(task_or_id, key), to: Actions.PickDesignDirection

  defdelegate recheck_design(scope, task_or_id, opts), to: Actions.RecheckDesign
  defdelegate recheck_design(a, b), to: Actions.RecheckDesign
  defdelegate recheck_design(task_or_id), to: Actions.RecheckDesign

  defdelegate uses_design?(task, runs \\ []), to: Rail.Pipeline.Schemas.Task
  defdelegate design_manifest_stamp(target), to: Actions.RecheckDesign
  defdelegate apply_design_manifest(scope, task, opts \\ []), to: Actions.RecheckDesign

  defdelegate decline_demo(scope_or_task, task_or_note, note), to: Actions.DeclineDemo
  defdelegate decline_demo(scope_or_task, task_or_note), to: Actions.DeclineDemo
  defdelegate decline_demo(task_or_id), to: Actions.DeclineDemo

  defdelegate rerecord_demo(scope_or_task, task_or_opts, opts), to: Actions.RerecordDemo
  defdelegate rerecord_demo(scope_or_task, task_or_opts), to: Actions.RerecordDemo
  defdelegate rerecord_demo(task_or_id), to: Actions.RerecordDemo
  defdelegate can_rerecord_demo?(task), to: Actions.RerecordDemo

  defdelegate refresh_demo_freshness(scope_or_task, task_or_opts, opts), to: Actions.RefreshDemoFreshness
  defdelegate refresh_demo_freshness(scope_or_task, task_or_opts), to: Actions.RefreshDemoFreshness
  defdelegate refresh_demo_freshness(task_or_id), to: Actions.RefreshDemoFreshness

  defdelegate send_back_to_engineer(scope, task_or_id, opts), to: Actions.SendBackToEngineer
  defdelegate send_back_to_engineer(scope_or_task, task_or_opts), to: Actions.SendBackToEngineer
  defdelegate send_back_to_engineer(task_or_id), to: Actions.SendBackToEngineer

  defdelegate skip_to_ready_to_merge(scope, task_or_id), to: Actions.SkipToReadyToMerge
  defdelegate skip_to_ready_to_merge(task_or_id), to: Actions.SkipToReadyToMerge

  defdelegate retry_stage(scope, task_or_id, opts), to: Actions.RetryStage
  defdelegate retry_stage(scope_or_task, task_or_opts), to: Actions.RetryStage
  defdelegate retry_stage(task_or_id), to: Actions.RetryStage

  defdelegate cancel_task(scope, task_or_id, opts), to: Actions.CancelTask
  defdelegate cancel_task(scope_or_task, task_or_opts), to: Actions.CancelTask
  defdelegate cancel_task(task_or_id), to: Actions.CancelTask

  defdelegate register_question(task_or_id, run_or_id, question_or_attrs, opts), to: Actions.RegisterQuestion
  defdelegate register_question(task_or_id, run_or_question, question_or_opts), to: Actions.RegisterQuestion
  defdelegate register_question(task_or_id, question_or_attrs), to: Actions.RegisterQuestion
  defdelegate register_questions(task_or_id, run_or_id, questions, opts \\ []), to: Actions.RegisterQuestion

  defdelegate answer_questions(scope, task_or_id, answers, opts), to: Actions.AnswerQuestions
  defdelegate answer_questions(a, b, c), to: Actions.AnswerQuestions
  defdelegate answer_questions(task_or_id, answers), to: Actions.AnswerQuestions

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

  defdelegate send_chat_turn(scope, task_or_id, role_id, text, opts), to: Actions.SendChatTurn
  defdelegate send_chat_turn(scope_or_task, task_or_role, role_or_text, text_or_opts), to: Actions.SendChatTurn
  defdelegate send_chat_turn(task_or_id, role_id, text), to: Actions.SendChatTurn
  defdelegate dispatch_chat_turn(task, role, run, opts), to: Actions.SendChatTurn
  defdelegate dispatch_chat_turn(task, role, run), to: Actions.SendChatTurn
  defdelegate maybe_dispatch_queued_pending_chat(task, opts), to: Actions.SendChatTurn
  defdelegate maybe_dispatch_queued_pending_chat(task), to: Actions.SendChatTurn

  defdelegate stop_chat_turn(scope, task_or_id), to: Actions.StopChatTurn
  defdelegate stop_chat_turn(task_or_id), to: Actions.StopChatTurn

  defdelegate cancel_pending_chat(scope, task_or_id, role_id), to: Actions.CancelPendingChat
  defdelegate cancel_pending_chat(task_or_id, role_id), to: Actions.CancelPendingChat

  defdelegate settle_chat_turn(task_target, run_target, run_or_outcome, opts), to: Actions.SettleChatTurn
  defdelegate settle_chat_turn(task_target, run_target, run_or_outcome), to: Actions.SettleChatTurn
  defdelegate settle_chat_turn(task_target, run_target), to: Actions.SettleChatTurn

  defdelegate refresh_mergeability(scope_or_task, task_or_opts, opts), to: Actions.RefreshMergeability
  defdelegate refresh_mergeability(scope_or_task, task_or_opts), to: Actions.RefreshMergeability
  defdelegate refresh_mergeability(task_or_id), to: Actions.RefreshMergeability

  defdelegate mark_pr_ready(scope_or_task, task_or_opts, opts), to: Actions.MarkPrReady
  defdelegate mark_pr_ready(scope_or_task, task_or_opts), to: Actions.MarkPrReady
  defdelegate mark_pr_ready(task_or_id), to: Actions.MarkPrReady

  defdelegate start_rebase(scope_or_task, task_or_opts, opts), to: Actions.StartRebase
  defdelegate start_rebase(scope_or_task, task_or_opts), to: Actions.StartRebase
  defdelegate start_rebase(task_or_id), to: Actions.StartRebase

  defdelegate merge_task(scope_or_task, task_or_opts, opts), to: Actions.MergeTask
  defdelegate merge_task(scope_or_task, task_or_opts), to: Actions.MergeTask
  defdelegate merge_task(task_or_id), to: Actions.MergeTask

  defdelegate cleanup_task(scope_or_task, task_or_opts, opts), to: Actions.CleanupTask
  defdelegate cleanup_task(scope_or_task, task_or_opts), to: Actions.CleanupTask
  defdelegate cleanup_task(task_or_id), to: Actions.CleanupTask

  defdelegate load_diff(scope_or_task, task_or_opts), to: Actions.LoadDiff
  defdelegate load_diff(task), to: Actions.LoadDiff
  defdelegate reconcile_viewed_diff_files(task, parsed_files), to: Actions.ReconcileViewedDiffFiles
  defdelegate set_diff_file_viewed(scope, task, file_path, file_digest, viewed), to: Actions.SetDiffFileViewed
  defdelegate set_diff_file_viewed(task, file_path, file_digest, viewed), to: Actions.SetDiffFileViewed
  defdelegate expand_diff_gap(task, file_path, gap_index, start_line, end_line, diff_rev), to: Actions.ExpandDiffGap
end
