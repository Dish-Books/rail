defmodule Rail.Pipeline.Actions.CreateScreenCommentTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ScreenComment
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Users

  setup %{project: project} do
    task = learnings_task(project, "CSC-1", :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    folder = Path.join([task.scratch_path, "qa", "screens", "file-list"])
    File.mkdir_p!(folder)
    File.write!(Path.join(folder, "1.jpg"), "jpeg")
    {:ok, _shot} = Pipeline.save_screen(task, %{key: "file-list", label: "File list", file: "screens/file-list/1.jpg"})

    {:ok, %{id: user_id} = ada} =
      Users.register_oauth_user(%{github_id: "gh_csc_ada", login: "ada", email: "ada@example.com"})

    %{task: task, ada: user_scope(user: ada), user_id: user_id}
  end

  # The label and the commit are the shot's, never the client's.
  test "saves the comment on a listed state against its shot, for its author", %{
    task: %{id: task_id} = task,
    ada: ada,
    user_id: user_id
  } do
    assert {:ok,
            %ScreenComment{
              task_id: ^task_id,
              user_id: ^user_id,
              key: "file-list",
              label: "File list",
              commit: nil,
              body: "Fold the count.",
              status: :unsent
            }} =
             Pipeline.create_screen_comment(ada, task, %{
               "key" => "file-list",
               "body" => " Fold the count. ",
               "label" => "Forged",
               "commit" => "abc1234",
               "status" => "sent"
             })
  end

  test "takes a comment after the review is finished, at Finalize and after the merge", %{
    project: project,
    task: task,
    ada: ada
  } do
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :review_lead)

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :finished, started_at: DateTime.utc_now()})

    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, _finished} = Pipeline.start_fix_round(system_scope(), run)

    assert [%{finished_at: %DateTime{}}] = Pipeline.read_review(task)
    assert %Task{stage: :finalize} = finalizing = Repo.reload!(task)
    assert {:ok, %ScreenComment{}} = Pipeline.create_screen_comment(ada, task, %{"key" => "file-list", "body" => "Hi."})

    {:ok, _merged} = Pipeline.update_task(finalizing, %{stage: :merged})
    assert {:ok, %ScreenComment{}} = Pipeline.create_screen_comment(ada, task, %{"key" => "file-list", "body" => "Hi."})
  end

  test "refuses a state that is not listed, a task back before Review, and a cleaned-up task", %{task: task, ada: ada} do
    attrs = %{"key" => "file-list", "body" => "Fold it."}

    assert {:error, :not_found} = Pipeline.create_screen_comment(ada, task, %{attrs | "key" => "toolbar"})
    assert {:error, %Ecto.Changeset{}} = Pipeline.create_screen_comment(ada, task, %{attrs | "body" => " "})

    {:ok, engineering} = Pipeline.update_task(task, %{stage: :engineer})
    assert {:error, {:invalid_stage, :engineer}} = Pipeline.create_screen_comment(ada, task, attrs)

    {:ok, _cleaned} = Pipeline.update_task(engineering, %{stage: :finalize, cleaned_up_at: DateTime.utc_now()})
    assert {:error, :cleaned_up} = Pipeline.create_screen_comment(ada, task, attrs)
    assert Repo.all(ScreenComment) == []
  end

  test "tells the author's pages on the task, and nobody else's", %{task: %{id: task_id} = task, ada: ada} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "screen_comments:#{task_id}:#{ada.user.id}")
    Phoenix.PubSub.subscribe(Rail.PubSub, "screen_comments:#{task_id}:usr_someone_else")

    {:ok, _saved} = Pipeline.create_screen_comment(ada, task, %{"key" => "file-list", "body" => "Fold it."})

    assert_received {:screen_comments_changed, ^task_id}
    refute_received {:screen_comments_changed, _task_id}
  end
end
