defmodule Rail.Pipeline.Actions.ListPlanCommentsTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.PlanComment
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
            "issue" => %{"id" => "lin_pcm_list_1", "identifier" => "PCL-1", "title" => "Plan Comments"}
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
      ~s({"options": [{"key": "waiting-lanes", "title": "Lanes"}, {"key": "one-queue", "title": "Queue"}]})
    )

    File.write!(Path.join(dir, "picked"), "waiting-lanes")

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_list_plan_comment",
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

  test "returns only the reader's own unsent comments, never a teammate's and never a sent one", %{
    task: task,
    run: run,
    ada: ada,
    grace: grace,
    attrs: attrs
  } do
    {:ok, %{id: sent_id}} = Pipeline.create_plan_comment(ada, run, %{attrs | body: "Sent first."})
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
    {:ok, :sent, _run} = Pipeline.send_plan_comments(ada, run)
    {:ok, %{id: adas_id}} = Pipeline.create_plan_comment(ada, run, attrs)
    {:ok, %{id: graces_id}} = Pipeline.create_plan_comment(grace, run, attrs)

    assert [%PlanComment{id: ^adas_id, status: :unsent}] = Pipeline.list_plan_comments(ada, task)
    assert [%PlanComment{id: ^graces_id}] = Pipeline.list_plan_comments(grace, task)
    refute sent_id in Enum.map(Pipeline.list_plan_comments(ada, task), & &1.id)
  end

  test "comments written in the same instant come back in id order", %{task: task, run: run, ada: ada, attrs: attrs} do
    {:ok, first} = Pipeline.create_plan_comment(ada, run, %{attrs | body: "One."})
    {:ok, second} = Pipeline.create_plan_comment(ada, run, %{attrs | body: "Two."})
    Repo.update_all(from(c in PlanComment, where: c.task_id == ^task.id), set: [inserted_at: first.inserted_at])

    assert Enum.map(Pipeline.list_plan_comments(ada, task), & &1.id) == Enum.sort([first.id, second.id])
  end

  test "a design comment and then a ticket comment come back as 1 and 2 to their author alone, and a later design
        comment moves ahead of the ticket's",
       %{task: task, run: run, ada: ada, grace: grace, attrs: attrs} do
    {:ok, _ticket} = Pipeline.save_ticket(task, %{title: "Lanes", description: "- Group by project."})
    {:ok, %{id: first_design}} = Pipeline.create_plan_comment(ada, run, attrs)

    {:ok, %{id: ticket_id}} =
      Pipeline.create_plan_comment(ada, run, %{
        target: :ticket,
        element_kind: :list_item,
        element_label: "Item 1",
        element_occurrence: 1,
        element_text: "Group by project.",
        body: "Say which project."
      })

    assert [%PlanComment{id: ^first_design}, %PlanComment{id: ^ticket_id}] = Pipeline.list_plan_comments(ada, task)
    assert Pipeline.list_plan_comments(grace, task) == []

    {:ok, %{id: later_design}} = Pipeline.create_plan_comment(ada, run, %{attrs | body: "Later."})

    assert [%{id: ^first_design}, %{id: ^later_design}, %{id: ^ticket_id}] = Pipeline.list_plan_comments(ada, task)
  end
end
