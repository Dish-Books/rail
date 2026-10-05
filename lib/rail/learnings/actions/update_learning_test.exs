defmodule Rail.Learnings.Actions.UpdateLearningTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Learnings.Workers.EmbedLearning

  test "new text is queued for embedding and leaves search until the job runs", %{project: project} do
    stub_vertex(%{"factory" => vector([1.0])})
    rule = learning(project, %{rule: "Use the factory", kind: :convention}, embedding: [1.0])
    Repo.delete_all(Oban.Job)

    assert {:ok, %Learning{rule: "Use the factory builders", embedding: nil}} =
             Learnings.update_learning(system_scope(), rule, %{rule: "Use the factory builders"})

    assert_enqueued(worker: EmbedLearning, args: %{learning_id: rule.id})
    assert {:ok, []} = Learnings.list_learnings(project_id: project.id, query: "factory")
  end

  test "a change to anything but the text keeps the embedding and queues nothing", %{project: project} do
    rule = learning(project, %{rule: "Use the factory", kind: :convention}, embedding: [1.0])
    Repo.delete_all(Oban.Job)

    assert {:ok, %Learning{pinned: true, embedding: %Pgvector{}}} =
             Learnings.update_learning(system_scope(), rule, %{pinned: true, roles: [:engineer]})

    refute_enqueued(worker: EmbedLearning)
  end

  test "a proposal's draft is edited the same way", %{project: project} do
    draft = learning(project, %{rule: "Draft", kind: :convention}, status: :proposed)
    Repo.delete_all(Oban.Job)

    assert {:ok, %Learning{rule: "Better draft", status: :proposed}} =
             Learnings.update_learning(system_scope(), draft, %{rule: "Better draft"})

    assert_enqueued(worker: EmbedLearning, args: %{learning_id: draft.id})
  end

  test "an edit is the ruling on an override flagging the rule", %{project: project} do
    rule = learning(project, %{rule: "Don't flag docs", kind: :calibration})
    override = Repo.insert!(%LearningProposal{project_id: project.id, action: :override, learning_id: rule.id})

    assert {:ok, _edited} = Learnings.update_learning(system_scope(), rule, %{rule: "Don't flag private docs"})
    assert %LearningProposal{status: :approved} = Repo.reload!(override)
  end

  test "an invalid edit is refused", %{project: project} do
    rule = learning(project, %{rule: "Use the factory", kind: :convention})

    assert {:error, %Ecto.Changeset{}} = Learnings.update_learning(system_scope(), rule, %{rule: ""})
  end
end
