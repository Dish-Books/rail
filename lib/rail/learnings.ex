defmodule Rail.Learnings do
  @moduledoc """
  Public context for the knowledge base: the rules each project learned, the sightings behind them and the proposals that change them.
  Agents never write rules; corrections become provisional when sent, and only the curator's three-task check activates one unasked.
  """

  alias Rail.Learnings.Actions

  defdelegate list_learnings(opts \\ []), to: Actions.ListLearnings
  defdelegate count_learnings(opts \\ []), to: Actions.CountLearnings
  defdelegate get_learning(id), to: Actions.GetLearning
  defdelegate get_learning_stats(learning), to: Actions.GetLearningStats
  defdelegate create_learning(scope, project, attrs), to: Actions.CreateLearning
  defdelegate update_learning(scope, learning, attrs), to: Actions.UpdateLearning
  defdelegate retire_learning(scope, learning), to: Actions.RetireLearning
  defdelegate embed_learning(learning), to: Actions.EmbedLearning
  defdelegate list_learning_proposals(opts \\ []), to: Actions.ListLearningProposals
  defdelegate get_learning_proposal(id), to: Actions.GetLearningProposal
  defdelegate approve_learning_proposal(scope, proposal), to: Actions.ApproveLearningProposal
  defdelegate reject_learning_proposal(scope, proposal), to: Actions.RejectLearningProposal
  defdelegate retrieve_learnings(target, queries), to: Actions.RetrieveLearnings
  defdelegate record_corrections(task, records), to: Actions.RecordCorrections
  defdelegate record_overrides(task, findings), to: Actions.RecordOverrides
  defdelegate match_past_answer(task, question), to: Actions.MatchPastAnswer
  defdelegate handle_issue_finished(issue), to: Actions.HandleIssueFinished
  defdelegate extract_task_learnings(task), to: Actions.ExtractTaskLearnings
  defdelegate curate_learnings(project), to: Actions.CurateLearnings
  defdelegate get_latest_curator_pass(project), to: Actions.GetLatestCuratorPass
  defdelegate backfill_learnings(project), to: Actions.BackfillLearnings
end
