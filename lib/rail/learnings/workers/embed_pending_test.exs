defmodule Rail.Learnings.Workers.EmbedPendingTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Workers.EmbedLearning
  alias Rail.Learnings.Workers.EmbedPending

  setup %{project: project} do
    unembedded = learning(project, %{rule: "Never embedded", kind: :convention})
    stale = learning(project, %{rule: "Stale model", kind: :convention}, status: :provisional, embedding: [1.0])
    Repo.update_all(from(l in Learning, where: l.id == ^stale.id), set: [embedding_model: "older-model"])
    draft = learning(project, %{rule: "Draft", kind: :convention}, status: :proposed, embedding: nil)
    current = learning(project, %{rule: "Current", kind: :convention}, embedding: [1.0])
    retired = learning(project, %{rule: "Retired", kind: :convention}, status: :retired, embedding: nil)
    Repo.delete_all(Oban.Job)

    %{waiting: [unembedded, stale, draft], skipped: [current, retired]}
  end

  test "queues one embedding per live rule without one for the current model, and none twice", %{
    waiting: waiting,
    skipped: skipped
  } do
    stub(Rail, :goth_enabled?, fn -> true end)

    assert :ok = perform_job(EmbedPending, %{})
    assert :ok = perform_job(EmbedPending, %{})

    for rule <- waiting, do: assert([_one] = all_enqueued(worker: EmbedLearning, args: %{learning_id: rule.id}))
    for rule <- skipped, do: refute_enqueued(worker: EmbedLearning, args: %{learning_id: rule.id})
  end

  test "with Goth off it queues nothing, since every job would only cancel itself" do
    assert :ok = perform_job(EmbedPending, %{})
    refute_enqueued(worker: EmbedLearning)
  end
end
