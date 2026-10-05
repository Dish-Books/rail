defmodule Rail.Learnings.Actions.EmbedLearningTest do
  use Rail.DataCase, async: true

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning

  test "writes the embedding and the model, and tells an open page", %{project: %{id: project_id} = project} do
    stub_vertex(%{"Use the factory" => vector([1.0, 0.5])})
    rule = learning(project, %{rule: "Use the factory", kind: :convention})
    Phoenix.PubSub.subscribe(Rail.PubSub, "learnings")

    assert {:ok, %Learning{embedding: %Pgvector{}, embedding_model: "gemini-embedding-001"}} =
             Learnings.embed_learning(rule)

    assert_received {:embedded, "Use the factory", "RETRIEVAL_DOCUMENT"}
    assert_received {:learnings_changed, ^project_id}
  end

  test "a rule already embedded for its text and model makes no request", %{project: project} do
    stub_vertex()
    rule = learning(project, %{rule: "Use the factory", kind: :convention}, embedding: [1.0])

    assert {:ok, %Learning{embedding: %Pgvector{}}} = Learnings.embed_learning(rule)
    refute_received {:embedded, _text, _task_type}
  end

  test "an embedding for another model is written again", %{project: project} do
    stub_vertex()
    rule = learning(project, %{rule: "Use the factory", kind: :convention}, embedding: [1.0])
    Repo.update_all(from(l in Learning, where: l.id == ^rule.id), set: [embedding_model: "older-model"])

    assert {:ok, %Learning{embedding_model: "gemini-embedding-001"}} = Learnings.embed_learning(rule)
    assert_received {:embedded, "Use the factory", "RETRIEVAL_DOCUMENT"}
  end

  test "a rule edited after the job read it is left unembedded for its own job", %{project: project} do
    rule = learning(project, %{rule: "Use the factory", why: "Rows stay valid", kind: :convention})
    stub_vertex()

    Req.Test.stub(Rail.Learnings.Clients.Vertex, fn conn ->
      {:ok, _edited} = Learnings.update_learning(system_scope(), Repo.get!(Learning, rule.id), %{rule: "Use builders"})
      Req.Test.json(conn, %{"predictions" => [%{"embeddings" => %{"values" => vector([1.0])}}]})
    end)

    assert {:ok, %Learning{rule: "Use builders", embedding: nil}} = Learnings.embed_learning(rule)
  end

  test "a rule with no why is matched on its rule alone", %{project: project} do
    stub_vertex()
    rule = learning(project, %{rule: "Use the factory", kind: :convention})

    assert {:ok, %Learning{why: nil, embedding: %Pgvector{}}} = Learnings.embed_learning(rule)
  end

  test "a rule that is gone, or text that cannot be embedded, is an error", %{project: project} do
    rule = learning(project, %{rule: "Use the factory", kind: :convention})

    assert {:error, :goth_disabled} = Learnings.embed_learning(rule)
    assert {:error, :not_found} = Learnings.embed_learning(%Learning{id: "lrn_gone"})
  end
end
