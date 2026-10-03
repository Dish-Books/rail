defmodule Rail.Learnings.Schemas.ObservationTest do
  use ExUnit.Case, async: true

  alias Rail.Learnings.Schemas.Observation
  alias Rail.Users.Schemas.User

  test "every source kind reads as a label" do
    assert Enum.map(Observation.source_kinds(), &Observation.source_label/1) == [
             "Diff comment",
             "Fix on a review finding",
             "Fix on a QA finding",
             "Answer",
             "Fixed anyway",
             "PR review comment",
             "PR review",
             "Seen in a finished task"
           ]
  end

  test "who an observation is from is a Rail user, a GitHub login, or Rail" do
    assert Observation.actor_label(%Observation{actor: %User{name: "Dana"}, actor_name: "dana-gh"}) == "Dana"
    assert Observation.actor_label(%Observation{actor: nil, actor_name: "dana-gh"}) == "dana-gh"
    assert Observation.actor_label(%Observation{actor: nil}) == "Rail"
  end

  test "an observation needs a source kind and its text" do
    refute Observation.changeset(%Observation{}, %{}).valid?
    assert Observation.changeset(%Observation{}, %{source_kind: :extraction, text: "A lesson"}).valid?
  end
end
