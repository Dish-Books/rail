defmodule Rail.Pipeline.Actions.SendPlanCommentsTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users

  setup %{project: project} do
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :plan)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_pcm_send_1", "identifier" => "PCS-1", "title" => "Plan Comments"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Plan Comments"})
    {:ok, task} = Pipeline.create_task(issue, :plan)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})
    dir = Path.join(task.scratch_path, "design")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    File.write!(
      Path.join(dir, "manifest.json"),
      ~s({"options": [{"key": "waiting-lanes", "title": "Lanes by what they wait on"}]})
    )

    File.write!(Path.join(dir, "picked"), "waiting-lanes")

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_send_plan_comment",
        started_at: DateTime.utc_now()
      })

    {:ok, ada} = Users.register_oauth_user(%{github_id: "gh_pclist_ada", login: "ada", email: "ada@example.com"})
    {:ok, grace} = Users.register_oauth_user(%{github_id: "gh_pclist_grace", login: "grace", email: "grace@example.com"})

    attrs = %{
      target: :design,
      option_key: "waiting-lanes",
      selector: "#group-by-project",
      element_text: "Group by project",
      element_tag: "label",
      capture: %{html: ~s(<label id="group-by-project">Group by project</label>), width: 160, height: 20},
      body: "Turn this on by default."
    }

    %{
      task: task,
      role: role,
      run: run,
      dir: dir,
      attrs: attrs,
      ada: user_scope(user: ada),
      grace: user_scope(user: grace)
    }
  end

  test "an idle Plan gets one message naming the pick and every unsent comment, and they leave the list", %{
    task: task,
    run: run,
    ada: ada,
    attrs: attrs
  } do
    {:ok, _first} = Pipeline.create_plan_comment(ada, run, attrs)

    {:ok, _second} =
      Pipeline.create_plan_comment(ada, run, %{
        attrs
        | selector: "#lane-needs-you > header:nth-child(1) > span:nth-child(1)",
          element_text: "",
          element_tag: "span",
          body: "Amber only past an hour."
      })

    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, :sent, %Run{}} = Pipeline.send_plan_comments(ada, run)

    assert Enum.map(Pipeline.list_run_events(run), & &1.line) ==
             Enum.map(
               String.split(
                 """
                 2 comments on the design

                 On Lanes by what they wait on (waiting-lanes):

                 1. `#group-by-project` "Group by project"
                 > Turn this on by default.

                 2. `#lane-needs-you > header:nth-child(1) > span:nth-child(1)` <span>
                 > Amber only past an hour.\
                 """,
                 "\n"
               ),
               &"[human:#{ada.user.id}] #{&1}"
             )

    assert Pipeline.list_plan_comments(ada, task) == []
  end

  test "a second Send finds nothing to send", %{run: run, ada: ada, attrs: attrs} do
    {:ok, _only} = Pipeline.create_plan_comment(ada, run, attrs)
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
    {:ok, :sent, _run} = Pipeline.send_plan_comments(ada, run)
    events = Pipeline.list_run_events(run)

    assert {:error, :nothing_to_send} = Pipeline.send_plan_comments(ada, run)
    assert Pipeline.list_run_events(run) == events
  end

  test "a working Plan gets the message queued", %{run: run, ada: ada, attrs: attrs} do
    {:ok, _only} = Pipeline.create_plan_comment(ada, run, attrs)
    {:ok, running} = Pipeline.update_run(run, %{status: :running})

    assert {:ok, :queued, %Run{pending_chat: "1 comment on the design" <> _rest}} =
             Pipeline.send_plan_comments(ada, running)
  end

  test "with the task at Engineer the message goes to the Plan run and resumes it", %{
    task: task,
    run: %{id: run_id} = run,
    ada: ada,
    attrs: attrs
  } do
    {:ok, _only} = Pipeline.create_plan_comment(ada, run, attrs)
    {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer})
    test_pid = self()

    stub(Tools, :start_os_process, fn spawned, _argv ->
      send(test_pid, {:resumed, spawned.id})
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, :sent, %Run{id: ^run_id}} = Pipeline.send_plan_comments(ada, run)
    assert_receive {:resumed, ^run_id}
  end

  test "each sent comment becomes one provisional Design rule for Designer, and a removed one or a resend adds none", %{
    task: %{id: task_id} = task,
    run: run,
    ada: %{user: %{id: ada_id}} = ada,
    attrs: attrs
  } do
    {:ok, %{id: kept_id}} = Pipeline.create_plan_comment(ada, run, attrs)
    {:ok, removed} = Pipeline.create_plan_comment(ada, run, %{attrs | body: "Never mind."})
    {:ok, _removed} = Pipeline.delete_plan_comment(ada, removed)
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    {:ok, :sent, _run} = Pipeline.send_plan_comments(ada, run)
    {:error, :nothing_to_send} = Pipeline.send_plan_comments(ada, run)

    assert [
             %Observation{
               source_kind: :design_comment,
               source_id: ^kept_id,
               actor_id: ^ada_id,
               task_id: ^task_id,
               capture: %{"html" => ~s(<label id="group-by-project">Group by project</label>), "width" => 160},
               learning: %{status: :provisional, kind: :design, roles: [:design], rule: "Turn this on by default."}
             }
           ] = Repo.all(from o in Observation, where: o.task_id == ^task.id, preload: :learning)
  end

  test "a run that cannot be messaged keeps the comments unsent and learns nothing", %{
    task: task,
    run: run,
    ada: ada,
    attrs: attrs
  } do
    {:ok, %{id: id}} = Pipeline.create_plan_comment(ada, run, attrs)
    Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [conversation_id: nil])

    assert {:error, :chat_unavailable} = Pipeline.send_plan_comments(ada, Repo.reload!(run))
    assert [%PlanComment{id: ^id, status: :unsent}] = Pipeline.list_plan_comments(ada, task)
    assert [] = Repo.all(from o in Observation, where: o.task_id == ^task.id)
  end

  test "another person's unsent comments are neither sent, numbered nor learned from", %{
    task: task,
    run: run,
    ada: ada,
    grace: grace,
    attrs: attrs
  } do
    {:ok, _adas} = Pipeline.create_plan_comment(ada, run, %{attrs | body: "Ada's"})
    {:ok, %{id: graces_id}} = Pipeline.create_plan_comment(grace, run, %{attrs | body: "Grace's"})
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, :sent, %Run{}} = Pipeline.send_plan_comments(ada, run)

    lines = run |> Pipeline.list_run_events() |> Enum.map_join("\n", & &1.line)
    assert lines =~ "1 comment on the design"
    refute lines =~ "Grace's"
    assert [%PlanComment{id: ^graces_id, status: :unsent}] = Pipeline.list_plan_comments(grace, task)
    assert [%Observation{text: "Ada's"}] = Repo.all(from o in Observation, where: o.task_id == ^task.id)
  end

  test "only the author's tabs are told, and only once the comments are sent", %{
    task: %{id: task_id},
    run: run,
    ada: ada,
    grace: grace,
    attrs: attrs
  } do
    {:ok, _only} = Pipeline.create_plan_comment(ada, run, attrs)
    Phoenix.PubSub.subscribe(Rail.PubSub, "plan_comments:#{task_id}:#{ada.user.id}")
    Phoenix.PubSub.subscribe(Rail.PubSub, "plan_comments:#{task_id}:#{grace.user.id}")

    stub(Tools, :start_os_process, fn spawned, _argv ->
      refute_received {:plan_comments_changed, _task_id}
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, :sent, %Run{}} = Pipeline.send_plan_comments(ada, run)
    assert_receive {:plan_comments_changed, ^task_id}
    refute_receive {:plan_comments_changed, ^task_id}
  end
end
