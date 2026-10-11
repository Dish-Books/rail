defmodule Rail.Pipeline.Actions.DeleteScreenCommentTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ScreenComment
  alias Rail.Users

  setup %{project: project} do
    task = learnings_task(project, "DSC-1", :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    File.mkdir_p!(Path.join([task.scratch_path, "qa", "screens", "toolbar"]))
    File.write!(Path.join([task.scratch_path, "qa", "screens", "toolbar", "1.jpg"]), "jpeg")
    {:ok, _shot} = Pipeline.save_screen(task, %{key: "toolbar", label: "Toolbar", file: "screens/toolbar/1.jpg"})

    {:ok, ada} = Users.register_oauth_user(%{github_id: "gh_dsc_ada", login: "ada", email: "ada@example.com"})
    {:ok, grace} = Users.register_oauth_user(%{github_id: "gh_dsc_grace", login: "grace", email: "grace@example.com"})
    {:ok, comment} = Pipeline.create_screen_comment(user_scope(user: ada), task, %{"key" => "toolbar", "body" => "Hi."})

    %{task: task, comment: comment, ada: user_scope(user: ada), grace: user_scope(user: grace)}
  end

  test "removes the author's own unsent comment and tells their pages", %{
    task: %{id: task_id} = task,
    comment: comment,
    ada: ada
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "screen_comments:#{task_id}:#{ada.user.id}")

    assert {:ok, %ScreenComment{}} = Pipeline.delete_screen_comment(ada, comment)
    assert Pipeline.list_screen_comments(ada, task) == []
    assert_received {:screen_comments_changed, ^task_id}
  end

  # A send that got there first, or another tab, leaves the row as it is.
  test "leaves a comment that was sent meanwhile", %{comment: %{id: id} = comment, ada: ada} do
    {1, nil} = Repo.update_all(from(c in ScreenComment, where: c.id == ^id), set: [status: :sent])

    assert {:ok, _comment} = Pipeline.delete_screen_comment(ada, comment)
    assert %ScreenComment{status: :sent} = Repo.get!(ScreenComment, id)
  end

  test "refuses another person's comment", %{comment: comment, grace: grace} do
    assert_raise FunctionClauseError, fn -> Pipeline.delete_screen_comment(grace, comment) end
    assert Repo.get!(ScreenComment, comment.id)
  end
end
