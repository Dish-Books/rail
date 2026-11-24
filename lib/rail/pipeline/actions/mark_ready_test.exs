defmodule Rail.Pipeline.Actions.MarkReadyTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.StartCurator
  alias Rail.Roles
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup %{project: project} do
    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Issue", description: "Mark Ready"})
    {:ok, task} = Pipeline.create_task(issue, :finalize)
    {:ok, task} = Pipeline.update_task(task, %{pr_number: 151})

    {:ok, dan} =
      Users.register_oauth_user(%{github_id: "gh_mr_dan", login: "dano-mark-ready", email: "dan-mark-ready@example.com"})

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

    assert [%Oban.Job{}] = all_enqueued(worker: StartCurator, args: %{task_id: task.id})
  end

  test "marking queues the task's curator pass, and marking again after a fix round queues another", %{
    task: %Task{id: task_id} = task,
    dan: dan
  } do
    {:ok, _marked} = Pipeline.mark_ready(Scope.for_user(dan), task)
    assert [%Oban.Job{args: %{"task_id" => ^task_id}}] = all_enqueued(worker: StartCurator)

    # The first pass ran, and a fix round took the mark off, so the next Ready for review is the task coming back.
    Repo.update_all(Oban.Job, set: [state: "completed", completed_at: DateTime.utc_now()])
    {:ok, unmarked} = task |> Repo.reload!() |> Pipeline.update_task(%{marked_ready_at: nil})
    {:ok, _marked} = Pipeline.mark_ready(Scope.for_user(dan), unmarked)
    assert [%Oban.Job{args: %{"task_id" => ^task_id}}] = all_enqueued(worker: StartCurator)
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
    assert {:error, :not_found} = Pipeline.mark_ready(Scope.for_user(dan), %Task{id: "tsk_deleted_since"})
    assert %Task{marked_ready_at: nil} = Repo.reload!(task)
    assert [] = all_enqueued(worker: StartCurator)
  end

  test "someone without GitHub is refused, read again in case they disconnected since the page loaded", %{
    task: task,
    dan: dan
  } do
    {:ok, unlinked} = dan |> Ecto.Changeset.change(github_id: nil) |> Repo.update()

    assert {:error, :github_not_linked} = Pipeline.mark_ready(Scope.for_user(dan), task)
    assert {:error, :github_not_linked} = Pipeline.mark_ready(Scope.for_user(unlinked), task)
    assert %Task{marked_ready_at: nil} = Repo.reload!(task)
    assert [] = all_enqueued(worker: StartCurator)
  end

  test "a task an agent works on again is refused, though the curator reading it is not", %{
    project: project,
    task: task,
    dan: dan,
    dan_id: dan_id
  } do
    {:ok, lead} = Roles.get_role(project_id: project.id, stage: :review_lead)
    {:ok, curator} = Roles.get_role(project_id: project.id, stage: :curator)
    running = %{task_id: task.id, status: :running, started_at: DateTime.utc_now()}
    {:ok, _reading} = Pipeline.create_run(Map.put(running, :role_id, curator.id))
    {:ok, resumed} = Pipeline.create_run(Map.put(running, :role_id, lead.id))

    assert {:error, :agent_working} = Pipeline.mark_ready(Scope.for_user(dan), task)
    assert %Task{marked_ready_at: nil} = Repo.reload!(task)

    {:ok, _done} = Pipeline.update_run(resumed, %{status: :finished, stage_outcome: :done})
    assert {:ok, %Task{marked_ready_by_id: ^dan_id}} = Pipeline.mark_ready(Scope.for_user(dan), task)
  end

  test "a task whose fix plan waits on approval is refused", %{task: task, dan: dan} do
    task = Repo.preload(task, :issue)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    path = Path.join([task.scratch_path, "fix_plans", "#{task.issue.identifier}.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{round: 1, findings: [], comments: [], plan: "p"}))

    assert {:error, :fix_plan_waiting} = Pipeline.mark_ready(Scope.for_user(dan), task)
    assert %Task{marked_ready_at: nil} = Repo.reload!(task)

    File.write!(path, Jason.encode!(%{round: 1, findings: [], comments: [], plan: "p", approved_at: DateTime.utc_now()}))
    assert {:ok, %Task{marked_ready_at: %DateTime{}}} = Pipeline.mark_ready(Scope.for_user(dan), task)
  end
end
