defmodule Rail.Pipeline.Actions.MarkReadyTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_mr_1", "identifier" => "MR-1", "title" => "Mark Ready"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Mark Ready"})
    {:ok, task} = Pipeline.create_task(issue, :finalize)
    {:ok, task} = Pipeline.update_task(task, %{pr_number: 151})

    {:ok, dan} = Users.register_oauth_user(%{github_id: "gh_mr_dan", login: "dano", email: "dan@example.com"})

    {:ok, %User{id: dan_id} = dan} =
      Users.update_user(system_scope(), dan, %{name: "Dan Okafor", project_ids: [project.id]})

    %{task: task, dan: dan, dan_id: dan_id}
  end

  test "marking records who and when, and every page hears it", %{
    task: %Task{id: task_id} = task,
    dan: dan,
    dan_id: dan_id
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")

    assert {:ok, %Task{marked_ready_by: %User{id: ^dan_id, name: "Dan Okafor"}, marked_ready_at: %DateTime{}}} =
             Pipeline.mark_ready(Scope.for_user(dan), task)

    assert %Task{marked_ready_by_id: ^dan_id} = Repo.reload!(task)
    assert_received {:pipeline_changed, ^task_id}
  end

  test "a second mark from another tab keeps the first", %{project: project, task: task, dan: dan, dan_id: dan_id} do
    {:ok, %Task{marked_ready_at: first_at}} = Pipeline.mark_ready(Scope.for_user(dan), task)
    {:ok, sam} = Users.register_oauth_user(%{github_id: "gh_mr_sam", login: "samito", email: "sam@example.com"})
    {:ok, sam} = Users.update_user(system_scope(), sam, %{project_ids: [project.id]})

    assert {:ok, %Task{marked_ready_by_id: ^dan_id, marked_ready_at: ^first_at}} =
             Pipeline.mark_ready(Scope.for_user(sam), task)
  end

  test "a task outside Finalize, one without a pull request, and another project's task are refused", %{
    task: task,
    dan: dan
  } do
    {:ok, reviewing} = Pipeline.update_task(task, %{stage: :review})
    assert {:error, {:invalid_stage, :review}} = Pipeline.mark_ready(Scope.for_user(dan), reviewing)

    {:ok, no_pr} = Pipeline.update_task(reviewing, %{stage: :finalize, pr_number: nil})
    assert {:error, :no_pull_request} = Pipeline.mark_ready(Scope.for_user(dan), no_pr)

    {:ok, _with_pr} = Pipeline.update_task(no_pr, %{pr_number: 151})
    assert {:error, :not_found} = Pipeline.mark_ready(Scope.for_user(%{dan | project_ids: []}), task)
    assert %Task{marked_ready_at: nil} = Repo.reload!(task)
  end
end
