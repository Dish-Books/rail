defmodule Rail.Learnings.Utils.ApplyProposal do
  @moduledoc """
  Carries out an approved proposal. A person's approval and the curator's
  auto-activation both end here, inside the caller's transaction.
  """

  import Ecto.Query

  alias Rail.Issues
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Applies `proposal` as `scope`: a system scope activates its draft as `auto`.
  Returns `{:ok, proposal}`, or the error opening a promotion's issue gave.
  """
  def apply_proposal(%Scope{} = scope, %LearningProposal{} = proposal) do
    %LearningProposal{learning: %Learning{} = learning} = proposal = Repo.preload(proposal, [:project, :learning])
    now = DateTime.utc_now()

    case proposal.action do
      action when action in [:add, :merge, :rewrite] ->
        learning
        |> Ecto.Changeset.change(
          status: :active,
          activated_at: now,
          auto: scope.system,
          approved_by_id: scope.user && scope.user.id
        )
        |> Repo.update!()

        retire(proposal, proposal.target_ids, now)
        {:ok, proposal}

      :retire ->
        retire(proposal, [learning.id], now)
        {:ok, proposal}

      :promote ->
        promote(scope, proposal)

      _conflict_or_override ->
        {:ok, proposal}
    end
  end

  defp retire(%LearningProposal{project_id: project_id}, ids, now) do
    Repo.update_all(
      from(l in Learning, where: l.id in ^ids and l.project_id == ^project_id and l.status != :retired),
      set: [status: :retired, retired_at: now, updated_at: now]
    )

    Repo.update_all(
      from(p in LearningProposal,
        where: p.learning_id in ^ids and p.project_id == ^project_id,
        where: p.action == :override and p.status == :pending
      ),
      set: [status: :approved, decided_at: now]
    )
  end

  # The rule stays active until the issue that replaces it is done.
  defp promote(%Scope{} = scope, %LearningProposal{learning: %Learning{} = learning} = proposal) do
    attrs = %{
      title:
        "Make #{LearningProposal.promote_label(proposal.promote_to || :claude_md)} of a rule that keeps being broken",
      description: """
      Rail's curator proposed promoting this rule out of the knowledge base, because agents given it keep breaking it.

      > #{learning.rule}

      #{learning.why || ""}

      #{proposal.summary || ""}

      Once this issue is done, Rail retires the rule.
      """
    }

    with {:ok, issue} <- Issues.create_issue(scope, proposal.project, attrs) do
      promoted = proposal |> Ecto.Changeset.change(issue_id: issue.id) |> Repo.update!()
      {:ok, promoted}
    end
  end
end
