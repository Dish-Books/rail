defmodule Rail.Learnings.Actions.CreateLearningTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Workers.EmbedLearning
  alias Rail.Users

  test "a person's rule is active at once, approved by them, queued for embedding and broadcast", %{
    project: %{id: project_id} = project
  } do
    {:ok, %{id: user_id} = user} =
      Users.register_oauth_user(%{github_id: "cl-1", login: "dana", name: "Dana", email: "dana@example.com"})

    Phoenix.PubSub.subscribe(Rail.PubSub, "learnings")

    assert {:ok, %Learning{id: id, status: :active, approved_by_id: ^user_id, activated_at: %DateTime{}, auto: false}} =
             Learnings.create_learning(Rail.Scope.for_user(user), project, %{rule: "Use the factory", kind: :convention})

    assert_enqueued(worker: EmbedLearning, args: %{learning_id: id})
    assert_received {:learnings_changed, ^project_id}
  end

  test "an invalid rule is refused and nothing is queued", %{project: project} do
    assert {:error, %Ecto.Changeset{}} =
             Learnings.create_learning(system_scope(), project, %{rule: "", kind: :convention})

    refute_enqueued(worker: EmbedLearning)
  end
end
