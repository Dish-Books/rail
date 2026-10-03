defmodule Rail.Learnings.Actions.MatchPastAnswerTest do
  use Rail.DataCase, async: true

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Pipeline.Schemas.Question

  setup %{project: project} do
    task = learnings_task(project, "GAT-1")
    past = %Question{id: "qst_gat_1", prompt: "Indigo or blue?", answer: "Blue.", status: :answered}
    {:ok, [rule]} = Learnings.record_corrections(task, [past])

    Repo.update_all(from(l in Learning, where: l.id == ^rule.id),
      set: [embedding: Pgvector.new(vector([1.0])), embedding_model: "gemini-embedding-001"]
    )

    %{task: task, rule: rule}
  end

  test "a close past answer answers, with its source", %{task: task, rule: %{id: rule_id}} do
    stub_vertex(%{"button color" => vector([1.0, 0.1])})

    assert {:answer,
            %{
              learning: %Learning{id: ^rule_id},
              observation: %Observation{excerpt: "Blue.", task: %{issue: %{identifier: "GAT-1"}}}
            }} =
             Learnings.match_past_answer(task, %Question{prompt: "Which button color?"})
  end

  test "a looser one is only a suggestion", %{task: task} do
    stub_vertex(%{"button color" => vector([1.0, 0.6])})

    assert {:suggestion, %{observation: %Observation{excerpt: "Blue."}}} =
             Learnings.match_past_answer(task, %Question{prompt: "Which button color?"})
  end

  test "an unrelated question, or a rule not recorded from an answer, matches nothing", %{project: project, task: task} do
    stub_vertex(%{"unrelated" => vector([0.0, 1.0]), "decision" => vector([0.0, 0.0, 1.0])})
    learning(project, %{rule: "A decision nobody asked", kind: :decision}, embedding: [0.0, 0.0, 1.0])

    assert nil == Learnings.match_past_answer(task, %Question{prompt: "Something unrelated"})
    assert nil == Learnings.match_past_answer(task, %Question{prompt: "the decision"})
  end

  test "an unembedded rule, or a prompt that cannot be embedded, matches nothing", %{task: task, rule: rule} do
    assert nil == Learnings.match_past_answer(task, %Question{prompt: "Which button color?"})

    stub_vertex()
    Repo.update_all(from(l in Learning, where: l.id == ^rule.id), set: [embedding: nil])
    assert nil == Learnings.match_past_answer(task, %Question{prompt: "Which button color?"})
    refute_received {:embedded, _text, _task_type}
  end
end
