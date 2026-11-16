defmodule Rail.Pipeline.Actions.CreateAppCommentTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ScreenComment
  alias Rail.Users

  setup %{project: project} do
    task = learnings_task(project, "CAC-1", :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, %{id: user_id} = ada} =
      Users.register_oauth_user(%{
        github_id: "gh_cac_ada",
        login: "ada-create-app-comment",
        email: "ada-create-app-comment@example.com"
      })

    # What `Rail.Tools.inspect_browser_element/5` says of the element a person picked.
    element = %{
      selector: "#checkout > button:nth-child(2)",
      text: "Pay now",
      tag: "button",
      url: "http://localhost:20650/checkout?step=2",
      picture: Path.join([task.scratch_path, "app", "elm_1.jpg"])
    }

    %{task: task, ada: user_scope(user: ada), user_id: user_id, element: element}
  end

  # The page is named as a person would, without the port the app happened to run on, against the worktree's commit.
  test "saves the comment on the element, on the page it is on, for its author", %{
    task: %{id: task_id} = task,
    ada: ada,
    user_id: user_id,
    element: %{picture: picture} = element
  } do
    File.mkdir_p!(task.worktree_path)
    on_exit(fn -> File.rm_rf(task.worktree_path) end)
    expect(Git, :branch_fingerprint, fn path when path == task.worktree_path -> %{head_sha: "e52a0bd91"} end)

    assert {:ok,
            %ScreenComment{
              task_id: ^task_id,
              user_id: ^user_id,
              source: :app,
              key: "app",
              label: "/checkout?step=2",
              commit: "e52a0bd91",
              selector: "#checkout > button:nth-child(2)",
              element_text: "Pay now",
              element_tag: "button",
              picture_path: ^picture,
              body: "Say the amount.",
              status: :unsent
            }} = Pipeline.create_app_comment(ada, task, element, " Say the amount. ")
  end

  test "a page at the app's root, or one not said, is /, and a worktree that is gone gives no commit", %{
    task: task,
    ada: ada,
    element: element
  } do
    reject(Git, :branch_fingerprint, 1)

    assert {:ok, %ScreenComment{label: "/", commit: nil}} =
             Pipeline.create_app_comment(ada, task, %{element | url: "http://localhost:20650"}, "Hi.")

    assert {:ok, %ScreenComment{label: "/?tab=open"}} =
             Pipeline.create_app_comment(ada, task, %{element | url: "http://localhost:20650?tab=open"}, "Hi.")

    assert {:ok, %ScreenComment{label: "/", picture_path: nil, element_text: nil}} =
             Pipeline.create_app_comment(ada, task, %{selector: "main"}, "Hi.")
  end

  test "takes a comment at Finalize and after the merge", %{task: task, ada: ada, element: element} do
    for stage <- [:finalize, :merged] do
      {:ok, _moved} = Pipeline.update_task(task, %{stage: stage})
      assert {:ok, %ScreenComment{}} = Pipeline.create_app_comment(ada, task, element, "Hi.")
    end
  end

  test "refuses an empty comment, a task back before Review, and a cleaned-up task", %{
    task: task,
    ada: ada,
    element: element
  } do
    assert {:error, %Ecto.Changeset{}} = Pipeline.create_app_comment(ada, task, element, " ")

    {:ok, engineering} = Pipeline.update_task(task, %{stage: :engineer})
    assert {:error, {:invalid_stage, :engineer}} = Pipeline.create_app_comment(ada, task, element, "Hi.")

    {:ok, _cleaned} = Pipeline.update_task(engineering, %{stage: :review, cleaned_up_at: DateTime.utc_now()})
    assert {:error, :cleaned_up} = Pipeline.create_app_comment(ada, task, element, "Hi.")
    assert Repo.all(ScreenComment) == []
  end

  test "tells the author's pages on the task, and nobody else's", %{
    task: %{id: task_id} = task,
    ada: ada,
    element: element
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "screen_comments:#{task_id}:#{ada.user.id}")
    Phoenix.PubSub.subscribe(Rail.PubSub, "screen_comments:#{task_id}:usr_someone_else")

    {:ok, _saved} = Pipeline.create_app_comment(ada, task, element, "Hi.")

    assert_received {:screen_comments_changed, ^task_id}
    refute_received {:screen_comments_changed, _task_id}
  end
end
