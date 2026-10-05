defmodule Rail.Learnings.Schemas.LearningProposalTest do
  use ExUnit.Case, async: true

  alias Rail.Learnings.Schemas.LearningProposal

  test "every action and promotion target reads as a label" do
    assert Enum.map([:add, :merge, :rewrite, :retire, :conflict, :promote, :override], &LearningProposal.action_label/1) ==
             ["Add", "Merge", "Rewrite", "Retire", "Conflict", "Promote", "Overridden"]

    assert Enum.map(LearningProposal.promote_targets(), &LearningProposal.promote_label/1) ==
             ["a lint check", "a role prompt", "a line in the repo's CLAUDE.md"]
  end

  test "only an add, a merge and a rewrite carry a draft" do
    assert Enum.filter(
             [:add, :merge, :rewrite, :retire, :conflict, :promote, :override],
             &LearningProposal.drafts?(%LearningProposal{action: &1})
           ) == [:add, :merge, :rewrite]
  end

  test "a proposal needs its action and its rule" do
    assert %{errors: [action: _action, learning_id: _learning]} = LearningProposal.changeset(%LearningProposal{}, %{})
  end
end
