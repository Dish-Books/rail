defmodule Rail.Pipeline.Actions.UpdateScreenCommentTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ScreenComment
  alias Rail.Users

  setup %{project: project} do
    task = learnings_task(project, "USC-1", :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    File.mkdir_p!(Path.join([task.scratch_path, "qa", "screens", "toolbar"]))
    File.write!(Path.join([task.scratch_path, "qa", "screens", "toolbar", "1.jpg"]), "jpeg")
    {:ok, _shot} = Pipeline.save_screen(task, %{key: "toolbar", label: "Toolbar", file: "screens/toolbar/1.jpg"})

    {:ok, ada} =
      Users.register_oauth_user(%{
        github_id: "gh_usc_ada",
        login: "ada-update-screen-comment",
        email: "ada-update-screen-comment@example.com"
      })

    {:ok, grace} =
      Users.register_oauth_user(%{
        github_id: "gh_usc_grace",
        login: "grace-update-screen-comment",
        email: "grace-update-screen-comment@example.com"
      })

    {:ok, comment} = Pipeline.create_screen_comment(user_scope(user: ada), task, %{"key" => "toolbar", "body" => "Hi."})

    %{task: task, comment: comment, ada: user_scope(user: ada), grace: user_scope(user: grace)}
  end

  test "the author changes an unsent comment's text and their tabs hear of it", %{
    task: %{id: task_id} = task,
    comment: comment,
    ada: ada
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "screen_comments:#{task_id}:#{ada.user.id}")

    assert {:ok, %ScreenComment{body: "Say why."}} =
             Pipeline.update_screen_comment(ada, comment, %{"body" => " Say why. "})

    assert [%ScreenComment{body: "Say why."}] = Pipeline.list_screen_comments(ada, task)
    assert_received {:screen_comments_changed, ^task_id}
  end

  test "a blank text is refused and the comment keeps its own", %{
    task: task,
    comment: %{body: text} = comment,
    ada: ada
  } do
    assert {:error, %Ecto.Changeset{}} = Pipeline.update_screen_comment(ada, comment, %{"body" => "  "})
    assert [%ScreenComment{body: ^text}] = Pipeline.list_screen_comments(ada, task)
  end

  # A send that got there first, or another tab, leaves the row as it is.
  test "a comment sent or removed meanwhile keeps the text it had", %{comment: %{id: id, body: text} = comment, ada: ada} do
    {1, nil} = Repo.update_all(from(c in ScreenComment, where: c.id == ^id), set: [status: :sent])

    assert {:error, :not_found} = Pipeline.update_screen_comment(ada, comment, %{"body" => "Say why."})
    assert %ScreenComment{status: :sent, body: ^text} = Repo.get!(ScreenComment, id)

    Repo.delete_all(from(c in ScreenComment, where: c.id == ^id))
    assert {:error, :not_found} = Pipeline.update_screen_comment(ada, comment, %{"body" => "Say why."})
  end

  test "refuses another person's comment, and a sent one", %{comment: comment, ada: ada, grace: grace} do
    assert_raise FunctionClauseError, fn -> Pipeline.update_screen_comment(grace, comment, %{"body" => "Mine now."}) end

    assert_raise FunctionClauseError, fn ->
      Pipeline.update_screen_comment(ada, %{comment | status: :sent}, %{"body" => "Say why."})
    end

    assert Repo.get!(ScreenComment, comment.id).body == comment.body
  end
end
