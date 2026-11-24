defmodule Rail.Triage.Schemas.ItemTest do
  use Rail.DataCase, async: true

  alias Rail.Triage.Schemas.Item

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

  test "a person's edit reaches the card's fields and nothing the pass owns" do
    item = %Item{issue_title: "Old", kind: :bug, verdict: :confirmed, followup_text: nil, ignored: false}

    expected = %{issue_title: "New", kind: :feature_request, followup_text: "Seen\nagain", ignored: true}

    assert %{valid?: true, changes: ^expected} =
             Item.draft_changeset(item, %{
               "issue_title" => "New",
               "kind" => "feature_request",
               "followup_text" => "Seen\r\nagain",
               "ignored" => "true",
               "verdict" => "built",
               "title" => "Changed"
             })

    assert %{kind: ["can't be blank"]} = errors_on(Item.draft_changeset(item, %{"kind" => ""}))
  end

  test "a verdict shows only while it fits the kind" do
    assert :confirmed = Item.fitting_verdict(%Item{kind: :bug, verdict: :confirmed})
    assert nil == Item.fitting_verdict(%Item{kind: :feature_request, verdict: :confirmed})
  end

  test "a person can change the estimate or clear it, but only to a point on the scale" do
    item = %Item{kind: :bug, issue_estimate: 3}

    assert %{valid?: true, changes: %{issue_estimate: 5}} = Item.draft_changeset(item, %{"issue_estimate" => "5"})
    assert %{valid?: true, changes: %{issue_estimate: nil}} = Item.draft_changeset(item, %{"issue_estimate" => ""})
    assert %{issue_estimate: ["is invalid"]} = errors_on(Item.draft_changeset(item, %{"issue_estimate" => "4"}))
    assert [1, 2, 3, 5, 8] = Item.estimates()
  end

  test "an existing issue means there is no issue draft" do
    assert Item.issue_draft?(%Item{issue_title: "Draft"})
    refute Item.issue_draft?(%Item{issue_title: "Draft", existing_issue_id: "iss_1"})
    refute Item.issue_draft?(%Item{issue_title: nil})
  end

  test "an untitled draft is no ticket, and a title of spaces is untitled" do
    refute Item.issue_draft?(%Item{issue_title: "  "})
    refute Item.to_create?(%Item{issue_title: ""})
  end

  test "an item is closed once its round was sent, its follow-up claimed, or its ticket created or claimed" do
    now = DateTime.utc_now()

    refute Item.closed?(%Item{})
    assert Item.closed?(%Item{sent_at: now})
    assert Item.closed?(%Item{followup_posted_at: now})
    assert Item.closed?(%Item{created_issue_id: "iss_1"})
    assert Item.closed?(%Item{issue_created_by_id: "usr_1"})
  end

  test "Send creates a titled, open item's ticket, and never an ignored or closed one's" do
    assert Item.to_create?(%Item{issue_title: "Bug"})
    refute Item.to_create?(%Item{issue_title: "Bug", ignored: true})
    refute Item.to_create?(%Item{issue_title: "Bug", issue_created_by_id: "usr_1"})
    refute Item.to_create?(%Item{issue_title: "Bug", existing_issue_id: "iss_1"})
  end

  test "Send adds a covered item's follow-up when there is one to add" do
    assert Item.to_update?(%Item{existing_issue_id: "iss_1", followup_text: "Seen again"})
    refute Item.to_update?(%Item{existing_issue_id: "iss_1", followup_text: "  "})
    refute Item.to_update?(%Item{existing_issue_id: "iss_1", followup_text: nil})
    refute Item.to_update?(%Item{existing_issue_id: nil, followup_text: "Seen again"})
    refute Item.to_update?(%Item{existing_issue_id: "iss_1", followup_text: "Seen again", ignored: true})

    refute Item.to_update?(%Item{
             existing_issue_id: "iss_1",
             followup_text: "Seen",
             followup_posted_at: DateTime.utc_now()
           })
  end

  test "labels" do
    assert "Could not reproduce" = Item.verdict_label(:not_reproduced)

    assert ["Confirmed", "Already fixed", "Built", "Partly built", "Not built"] =
             Enum.map([:confirmed, :already_fixed, :built, :partly_built, :not_built], &Item.verdict_label/1)

    assert "Bug" = Item.kind_label(:bug)
    assert "Feature request" = Item.kind_label(:feature_request)
  end
end
