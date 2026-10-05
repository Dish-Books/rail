defmodule Rail.Learnings.Workers.EmbedLearningTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Workers.EmbedLearning

  test "embeds the rule it names", %{project: project} do
    stub_vertex()
    rule = learning(project, %{rule: "Use the factory", kind: :convention})

    assert :ok = perform_job(EmbedLearning, %{learning_id: rule.id})
    assert %Learning{embedding: %Pgvector{}} = Repo.get!(Learning, rule.id)
  end

  test "with Goth off the job is cancelled rather than retried", %{project: project} do
    rule = learning(project, %{rule: "Use the factory", kind: :convention})

    assert {:cancel, :goth_disabled} = perform_job(EmbedLearning, %{learning_id: rule.id})
  end

  test "a failed request is retried", %{project: project} do
    stub_vertex_down()
    rule = learning(project, %{rule: "Use the factory", kind: :convention})

    assert {:error, {:vertex_error, 503, _body}} = perform_job(EmbedLearning, %{learning_id: rule.id})
  end

  test "a rule that is gone has nothing to embed" do
    assert :ok = perform_job(EmbedLearning, %{learning_id: "lrn_gone"})
  end

  test "is queued apart from agent passes, so an embedding never waits behind one", %{project: project} do
    rule = learning(project, %{rule: "Use the factory", kind: :convention})

    assert_enqueued(worker: EmbedLearning, args: %{learning_id: rule.id}, queue: :learnings_embed)
  end
end
