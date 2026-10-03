defmodule Rail.Learnings.Schemas.LearningTest do
  use Rail.DataCase, async: true

  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.Observation

  setup do
    %{
      learning: %Learning{
        rule: "Use the factory",
        why: "Rows stay valid",
        kind: :convention,
        embedding: Pgvector.new(vector([1.0])),
        embedding_model: "gemini-embedding-001"
      }
    }
  end

  test "changing the rule or the why clears the embedding, which was for the old text", %{learning: learning} do
    assert %{changes: %{embedding: nil, embedding_model: nil}} = Learning.changeset(learning, %{rule: "Use builders"})
    assert %{changes: %{embedding: nil, embedding_model: nil}} = Learning.changeset(learning, %{why: "Because"})
  end

  test "changing the kind, roles or pinned keeps the embedding", %{learning: learning} do
    changeset = Learning.changeset(learning, %{kind: :decision, roles: [:engineer], pinned: true})

    assert %{kind: :decision, roles: [:engineer], pinned: true} = changeset.changes
    refute Map.has_key?(changeset.changes, :embedding)
  end

  test "kind, roles and the rule are validated" do
    changeset = Learning.changeset(%Learning{}, %{rule: " ", kind: "nonsense", roles: ["curator"]})

    assert %{rule: ["can't be blank"], kind: ["is invalid"], roles: ["is invalid"]} = errors_on(changeset)
  end

  test "labels read the way the page says them" do
    assert Learning.roles_label(%Learning{roles: []}) == "Every role"
    assert Learning.roles_label(%Learning{roles: [:review, :design]}) == "Reviewer, Designer"

    assert Enum.map(Learning.kinds(), &Learning.kind_label/1) == [
             "Convention",
             "Decision",
             "Environment",
             "Product",
             "Design",
             "QA",
             "Calibration"
           ]

    assert Enum.map(Learning.statuses(), &Learning.status_label/1) == ["Proposed", "Provisional", "Active", "Retired"]

    assert Enum.map(Learning.roles(), &Learning.role_label/1) ==
             ["Product", "Designer", "Architect", "Engineer", "Reviewer", "QA", "Demo", "Debugger", "Triage"]
  end

  test "what is embedded is the rule and its why" do
    assert Learning.embedding_text(%Learning{rule: "A", why: "B"}) == "A\n\nB"
    assert Learning.embedding_text(%Learning{rule: "A"}) == "A"
  end

  test "a decision answers with the person's words until someone rewords it, whatever else sighted it" do
    sighting = %Observation{source_kind: :extraction, text: "Postgres?", excerpt: "Postgres."}
    answer = %Observation{source_kind: :answer, text: "Postgres or SQLite?", excerpt: "Postgres."}
    made = %Learning{rule: Learning.answer_rule("Postgres or SQLite?", "Postgres.")}

    assert made.rule == ~s(When asked "Postgres or SQLite?": Postgres.)
    assert "Postgres." = Learning.calculate_answer(made, [sighting, answer])
    assert "Postgres, with pgvector." = Learning.calculate_answer(%Learning{rule: "Postgres, with pgvector."}, [answer])
  end
end
