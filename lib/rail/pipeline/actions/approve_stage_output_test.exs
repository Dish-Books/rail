defmodule Rail.Pipeline.Actions.ApproveStageOutputTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Ecto.Query

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Schemas.IssueStage
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.StartEngineer
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_aso_1", "identifier" => "ASO-1", "title" => "Translation sync"}
          }
        }
      })
    end)

    stages = [
      %IssueStage{stage: :custom, name: "Missing strings", prompt: "List the keys with no translation."},
      %IssueStage{stage: :plan},
      %IssueStage{stage: :engineer},
      %IssueStage{stage: :review}
    ]

    {:ok, issue} =
      Issues.create_issue(system_scope(), project, %{
        title: "Translation sync",
        stages: stages,
        skipped_steps: [:product]
      })

    {:ok, task} = Pipeline.create_task(issue, {:custom, "Missing strings"})
    # HEAD is asked of Rail.Git, so the worktree is a plain directory on a branch with nothing changed.
    worktree_path = Path.join(task.scratch_path, "worktree")
    File.mkdir_p!(worktree_path)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    stub(Git, :branch_fingerprint, fn _path -> %{head_sha: String.duplicate("a", 40), dirty_digest: "clean"} end)
    {:ok, role} = Roles.get_custom_stage_role(project.id, "Missing strings")

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        conversation_id: "sess_approve_stage_output",
        started_at: DateTime.utc_now()
      })

    {:ok, ada} =
      Users.register_oauth_user(%{github_id: "gh_aso_ada", login: "ada-aso", email: "ada-aso@example.com"})

    {:ok, bob} =
      Users.register_oauth_user(%{github_id: "gh_aso_bob", login: "bob-aso", email: "bob-aso@example.com"})

    %{
      task: task,
      run: run,
      ada: user_scope(user: Map.put(ada, :project_ids, [project.id])),
      bob: user_scope(user: Map.put(bob, :project_ids, [project.id]))
    }
  end

  test "Approve with a file saved latches the run, deletes others' unsent comments and enqueues the next stage's start",
       %{task: %{id: task_id} = task, run: %{id: run_id} = run, ada: ada, bob: bob} do
    {:ok, _saved} = Pipeline.save_stage_output(task, %{markdown: "12 keys have no German entry."})

    {:ok, _comment} =
      Pipeline.create_plan_comment(bob, run, %{
        target: :output,
        body: "Say which screens.",
        element_kind: :paragraph,
        element_label: "Paragraph 1",
        element_occurrence: 1,
        element_text: "12 keys have no German entry."
      })

    Phoenix.PubSub.subscribe(Rail.PubSub, "plan_comments:#{task_id}:#{bob.user.id}")
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")
    reject(&Tools.start_os_process/2)

    assert {:ok, %Run{id: ^run_id, stage_outcome: :done, task: %Task{stage: :plan}}} =
             Pipeline.approve_stage_output(ada, run)

    assert %Task{stage: :plan, custom_stage: nil} = Repo.reload!(task)
    assert [] = Repo.all(from c in PlanComment, where: c.task_id == ^task_id)
    assert_received {:plan_comments_changed, ^task_id}
    assert_received {:pipeline_changed, ^task_id}
    assert_enqueued(worker: StartEngineer, args: %{task_id: task_id, stage: "plan"})
  end

  test "the job Approve enqueues starts Plan with the file in its brief", %{task: task, run: run, ada: ada} do
    {:ok, _saved} = Pipeline.save_stage_output(task, %{markdown: "12 keys have no German entry."})
    {:ok, _approved} = Pipeline.approve_stage_output(ada, run)
    assert [%Oban.Job{args: args}] = all_enqueued(worker: StartEngineer)

    expect(Tools, :start_os_process, fn %Run{role: %Role{stage: :plan}} = spawned, argv ->
      assert Enum.any?(argv, &(&1 =~ ~s(<stage_output stage="Missing strings">\n12 keys have no German entry.)))
      {:ok, %OsProcess{run: spawned, task: task}}
    end)

    assert :ok = perform_job(StartEngineer, args)

    # Product is off, so the Plan it entered holds the issue as its ticket.
    assert %Round{ticket: %Round.Ticket{title: "Translation sync"}} = Pipeline.read_plan(task)
  end

  test "Approve is refused while the approver has a comment unsent, which is kept", %{
    task: %{id: task_id} = task,
    run: run,
    ada: ada
  } do
    {:ok, _saved} = Pipeline.save_stage_output(task, %{markdown: "12 keys have no German entry."})

    {:ok, %PlanComment{id: comment_id}} =
      Pipeline.create_plan_comment(ada, run, %{
        target: :output,
        body: "Say which screens.",
        element_kind: :paragraph,
        element_label: "Paragraph 1",
        element_occurrence: 1,
        element_text: "12 keys have no German entry."
      })

    assert {:error, {:unsent_comments, 1}} = Pipeline.approve_stage_output(ada, run)

    assert %Task{stage: :custom, custom_stage: "Missing strings"} = Repo.reload!(task)
    assert %Run{stage_outcome: :in_progress} = Repo.reload!(run)
    assert [%PlanComment{id: ^comment_id}] = Repo.all(from c in PlanComment, where: c.task_id == ^task_id)
    refute_enqueued(worker: StartEngineer)
  end

  test "Approve is refused before a file is saved, while the agent works, and while a question waits", %{
    task: task,
    run: run,
    ada: ada
  } do
    reject(Tools, :start_os_process, 2)

    assert {:error, :no_output} = Pipeline.approve_stage_output(ada, run)

    {:ok, _saved} = Pipeline.save_stage_output(task, %{markdown: "12 keys."})
    {:ok, working} = run |> Run.changeset(%{status: :running}) |> Repo.update()
    assert {:error, :stage_running} = Pipeline.approve_stage_output(ada, working)

    {:ok, _idle} = working |> Run.changeset(%{status: :finished}) |> Repo.update()
    Repo.insert!(%Question{task_id: task.id, run_id: run.id, prompt: "German only?"})
    assert {:error, {:unanswered_questions, 1}} = Pipeline.approve_stage_output(ada, run)

    assert %Task{stage: :custom} = Repo.reload!(task)
    assert %Run{stage_outcome: :in_progress} = Repo.reload!(run)
  end

  test "a second click or tab after the first is refused, and starts nothing again", %{
    task: %{id: task_id} = task,
    run: run,
    ada: ada
  } do
    {:ok, _saved} = Pipeline.save_stage_output(task, %{markdown: "12 keys."})

    assert {:ok, %Run{}} = Pipeline.approve_stage_output(ada, run)
    assert {:error, {:invalid_stage, :plan}} = Pipeline.approve_stage_output(ada, run)
    assert [%Oban.Job{}] = all_enqueued(worker: StartEngineer, args: %{task_id: task_id})

    {:ok, _back} = Pipeline.update_task(Repo.reload!(task), %{stage: :custom, custom_stage: "Missing strings"})
    assert {:error, :already_approved} = Pipeline.approve_stage_output(ada, run)
  end

  test "a reader without the project cannot approve it", %{task: task, run: run} do
    {:ok, _saved} = Pipeline.save_stage_output(task, %{markdown: "12 keys."})
    outsider = %{id: "usr_aso_outsider", admin: false, project_ids: []}

    assert {:error, :not_found} = Pipeline.approve_stage_output(user_scope(user: outsider), run)
    assert %Task{stage: :custom} = Repo.reload!(task)
  end
end
