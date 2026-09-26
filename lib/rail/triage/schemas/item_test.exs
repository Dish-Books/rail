defmodule Rail.Triage.Schemas.ItemTest do
  use Rail.DataCase, async: true

  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Thread

  test "a verdict has to fit the item's kind" do
    base = %{key: "k", position: 1, title: "T"}

    assert %{valid?: true} = Item.triage_changeset(%Item{}, Map.merge(base, %{kind: :bug, verdict: :confirmed}))
    assert %{valid?: true} = Item.triage_changeset(%Item{}, Map.merge(base, %{kind: :feature_request, verdict: :built}))

    changeset = Item.triage_changeset(%Item{}, Map.merge(base, %{kind: :bug, verdict: :partly_built}))
    assert %{verdict: ["does not fit a bug"]} = errors_on(changeset)

    changeset = Item.triage_changeset(%Item{}, Map.merge(base, %{kind: :feature_request, verdict: :already_fixed}))
    assert %{verdict: ["does not fit a feature request"]} = errors_on(changeset)

    assert %{kind: ["can't be blank"]} = errors_on(Item.triage_changeset(%Item{}, base))
  end

  test "an edit marks only the draft it changed as edited" do
    item = %Item{issue_title: "Old", reply_text: "Hi"}

    assert %{changes: %{issue_title: "New", issue_edited_by_id: "usr_1"} = changes} =
             Item.draft_changeset(item, %{"issue_title" => "New", "reply_text" => "Hi"}, "usr_1")

    refute Map.has_key?(changes, :reply_edited_by_id)

    assert %{changes: %{reply_text: "Hello", reply_edited_by_id: "usr_2"} = reply_changes} =
             Item.draft_changeset(item, %{"reply_text" => "Hello"}, "usr_2")

    refute Map.has_key?(reply_changes, :issue_edited_by_id)
  end

  test "an existing issue means there is no issue draft" do
    assert Item.issue_draft?(%Item{issue_title: "Draft"})
    refute Item.issue_draft?(%Item{issue_title: "Draft", existing_issue_id: "iss_1"})
    refute Item.issue_draft?(%Item{issue_title: nil})
  end

  test "an item settles once everything it proposed was accepted" do
    now = DateTime.utc_now()

    refute Item.settled?(%Item{reply_text: "Thanks"})
    assert Item.settled?(%Item{reply_text: "Thanks", reply_posted_at: now})

    refute Item.settled?(%Item{issue_title: "Bug"})
    assert Item.settled?(%Item{issue_title: "Bug", created_issue_id: "iss_1"})

    refute Item.settled?(%Item{issue_title: "Bug", reply_text: "Thanks", created_issue_id: "iss_1"})
    assert Item.settled?(%Item{issue_title: "Bug", reply_text: "Thanks", created_issue_id: "iss_1", reply_posted_at: now})

    assert Item.settled?(%Item{issue_title: "Bug", reply_text: "Thanks", thread: %Thread{dismissed_at: now}})
    assert 2 = Item.pending_proposals(%Item{issue_title: "Bug", reply_text: "Thanks"})
    assert 0 = Item.pending_proposals(%Item{issue_title: "Bug", existing_issue_id: "iss_1"})
  end

  test "labels" do
    assert "Could not reproduce" = Item.verdict_label(:not_reproduced)

    assert ["Confirmed", "Already fixed", "Built", "Partly built", "Not built"] =
             Enum.map([:confirmed, :already_fixed, :built, :partly_built, :not_built], &Item.verdict_label/1)

    assert "Bug" = Item.kind_label(:bug)
    assert "Feature request" = Item.kind_label(:feature_request)
  end
end
