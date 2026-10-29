defmodule Rail.Pipeline.Actions.CreatePlanCommentTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Schemas.IssueStage
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Pipeline.Schemas.PlanCommentCapture
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Roles
  alias Rail.Users

  @plan """
  ## Implementation plan

  ### Approach

  One module decides.

  ### Decisions

  - Decision: one module changes.

  ### Changes

  #### `lib/rail.ex`

  Decides.

  ### Acceptance criteria

  - 1: `lib/rail.ex`

  ### Verification

  - `lib/rail_test.exs`: covers it.
  """

  setup %{project: project} do
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)
    stub(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :plan)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_pcm_create_1", "identifier" => "PCC-1", "title" => "Plan Comments"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Plan Comments"})
    {:ok, task} = Pipeline.create_task(issue, :plan)
    # Git is stubbed, so the worktree is only ever looked for: a plain directory stands in for it.
    worktree_path = Path.join(System.tmp_dir!(), "rail_cpc_wt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(worktree_path)
    on_exit(fn -> File.rm_rf(worktree_path) end)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    dir = Path.join(task.scratch_path, "design")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    File.write!(
      Path.join(dir, "manifest.json"),
      ~s({"options": [{"key": "waiting-lanes", "title": "Lanes"}, {"key": "one-queue", "title": "Queue"}]})
    )

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_create_plan_comment",
        started_at: DateTime.utc_now()
      })

    {:ok, ada} =
      Users.register_oauth_user(%{
        github_id: "gh_pcc_ada",
        login: "ada-create-plan-comment",
        email: "ada-create-plan-comment@example.com"
      })

    {:ok, grace} =
      Users.register_oauth_user(%{
        github_id: "gh_pcc_grace",
        login: "grace-create-plan-comment",
        email: "grace-create-plan-comment@example.com"
      })

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

  test "a design comment is refused before a design is picked", %{task: task, run: run, ada: ada, attrs: attrs} do
    assert {:error, :design_not_picked} = Pipeline.create_plan_comment(ada, run, attrs)
    assert Pipeline.list_plan_comments(ada, task) == []
  end

  test "a design comment is refused on an option other than the pick", %{run: run, dir: dir, ada: ada, attrs: attrs} do
    File.write!(Path.join(dir, "picked"), "one-queue")

    assert {:error, :not_the_pick} = Pipeline.create_plan_comment(ada, run, attrs)
  end

  test "a design comment on the pick is saved unsent for its author with its capture, and tells only their tabs", %{
    task: %{id: task_id} = task,
    run: run,
    dir: dir,
    ada: %{user: %{id: ada_id}} = ada,
    grace: grace,
    attrs: attrs
  } do
    File.write!(Path.join(dir, "picked"), "waiting-lanes")
    Phoenix.PubSub.subscribe(Rail.PubSub, "plan_comments:#{task_id}:#{ada_id}")
    Phoenix.PubSub.subscribe(Rail.PubSub, "plan_comments:#{task_id}:#{grace.user.id}")

    assert {:ok, %PlanComment{id: id, task_id: ^task_id, user_id: ^ada_id, status: :unsent}} =
             Pipeline.create_plan_comment(ada, run, attrs)

    assert [
             %PlanComment{
               id: ^id,
               selector: "#group-by-project",
               capture: %PlanCommentCapture{html: ~s(<label id="group-by-project">Group by project</label>), width: 160}
             }
           ] = Pipeline.list_plan_comments(ada, task)

    assert_receive {:plan_comments_changed, ^task_id}
    refute_receive {:plan_comments_changed, ^task_id}
  end

  test "with the task at Engineer a comment is saved while Plan can be messaged, and refused once it cannot", %{
    task: task,
    role: role,
    dir: dir,
    ada: ada,
    attrs: attrs
  } do
    File.write!(Path.join(dir, "picked"), "waiting-lanes")
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer})

    {:ok, chatty} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        conversation_id: "sess_engineer_stage",
        started_at: DateTime.utc_now()
      })

    {:ok, silent} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :finished, started_at: DateTime.utc_now()})

    assert {:ok, %PlanComment{}} = Pipeline.create_plan_comment(ada, chatty, attrs)
    assert {:error, :chat_unavailable} = Pipeline.create_plan_comment(ada, silent, attrs)
    assert {:error, :not_found} = Pipeline.create_plan_comment(ada, %Run{id: "run_gone"}, attrs)
  end

  test "a comment in the wrong shape is refused naming what is wrong", %{run: run, dir: dir, ada: ada, attrs: attrs} do
    File.write!(Path.join(dir, "picked"), "waiting-lanes")

    assert {:error, changeset} = Pipeline.create_plan_comment(ada, run, %{attrs | body: " "})
    assert %{body: ["can't be blank"]} = errors_on(changeset)
  end

  test "a ticket comment needs a saved ticket and a plan comment a saved plan", %{task: task, run: run, ada: ada} do
    line = %{element_kind: :paragraph, element_label: "Paragraph 1", element_occurrence: 1, body: "Say which pages."}
    ticket = Map.merge(line, %{target: :ticket, element_text: "Recordings open blank."})
    plan = Map.merge(line, %{target: :plan, element_text: "One module decides."})

    assert {:error, :no_ticket} = Pipeline.create_plan_comment(ada, run, ticket)
    assert {:error, :no_plan} = Pipeline.create_plan_comment(ada, run, plan)

    {:ok, _ticket} = Pipeline.save_plan(task, %{title: "Recordings", description: "Recordings open blank."})
    {:ok, _plan} = Pipeline.save_plan(task, %{plan: @plan})

    assert {:ok, %PlanComment{target: :ticket, element_label: "Paragraph 1", custom_stage: nil}} =
             Pipeline.create_plan_comment(ada, run, ticket)

    assert {:ok, %PlanComment{target: :plan, element_text: "One module decides."}} =
             Pipeline.create_plan_comment(ada, run, plan)
  end

  test "ticket and plan comments save while Plan can take a message, two on one line, and not once it cannot", %{
    task: task,
    role: role,
    run: chatty,
    ada: ada
  } do
    {:ok, _ticket} = Pipeline.save_plan(task, %{title: "Recordings", description: "Recordings open blank."})
    {:ok, _plan} = Pipeline.save_plan(task, %{plan: @plan})

    {:ok, silent} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :finished, started_at: DateTime.utc_now()})

    attrs = %{
      target: :ticket,
      element_kind: :title,
      element_label: "Title",
      element_occurrence: 1,
      element_text: "Recordings",
      body: "Say what settles."
    }

    assert {:ok, %PlanComment{}} = Pipeline.create_plan_comment(ada, chatty, attrs)
    assert {:ok, %PlanComment{}} = Pipeline.create_plan_comment(ada, chatty, %{attrs | body: "And when."})
    assert {:ok, %PlanComment{}} = Pipeline.create_plan_comment(ada, chatty, %{attrs | target: :plan})
    assert {:error, :chat_unavailable} = Pipeline.create_plan_comment(ada, silent, attrs)
    assert {:error, :chat_unavailable} = Pipeline.create_plan_comment(ada, silent, %{attrs | target: :plan})

    assert [%{body: "Say what settles."}, %{body: "And when."}, %{target: :plan}] =
             Pipeline.list_plan_comments(ada, task)
  end

  test "a comment on the next round's plan saves only while that plan is saved and waits on approval", %{
    task: task,
    run: run,
    ada: ada
  } do
    attrs = %{
      target: :fix_plan,
      element_kind: :paragraph,
      element_label: "Fix finding nil-crash, paragraph 1",
      element_occurrence: 1,
      element_text: "Guard nil.",
      body: "Guard it at the caller instead."
    }

    path = Path.join([task.scratch_path, "fix_plans", "PCC-1.json"])
    File.mkdir_p!(Path.dirname(path))

    assert {:error, :no_fix_plan} = Pipeline.create_plan_comment(ada, run, attrs)

    File.write!(path, Jason.encode!(%{round: 1, plan: nil, version: 0}))
    assert {:error, :no_fix_plan} = Pipeline.create_plan_comment(ada, run, attrs)

    File.write!(path, Jason.encode!(%{round: 1, plan: "Guard nil.", version: 1}))

    assert {:ok, %PlanComment{target: :fix_plan, status: :unsent, element_label: "Fix finding nil-crash, paragraph 1"}} =
             Pipeline.create_plan_comment(ada, run, attrs)

    File.write!(
      path,
      Jason.encode!(%{round: 1, plan: "Guard nil.", version: 1, approved_by: "ada", approved_at: DateTime.utc_now()})
    )

    assert {:error, :no_fix_plan} = Pipeline.create_plan_comment(ada, run, %{attrs | body: "And this."})
    assert [%PlanComment{body: "Guard it at the caller instead."}] = Pipeline.list_plan_comments(ada, task)
  end

  test "a comment on a custom stage's file is taken only at that stage, once its file is saved, through its own run", %{
    project: project,
    task: task,
    run: plan_run,
    ada: ada
  } do
    stages = [%IssueStage{stage: :custom, name: "License check", prompt: "Check each license."}]

    Repo.preload(task, :issue).issue
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_embed(:stages, stages)
    |> Repo.update!()

    {:ok, task} = Pipeline.update_task(task, %{stage: :custom, custom_stage: "License check"})
    {:ok, role} = Roles.get_custom_stage_role(project.id, "License check")

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        conversation_id: "sess_create_output_comment",
        started_at: DateTime.utc_now()
      })

    attrs = %{
      target: :output,
      body: "Say to replace it with saxy.",
      element_kind: :paragraph,
      element_label: "Paragraph 1",
      element_occurrence: 1,
      element_text: "sweet_xml 0.7.5 is AGPL-3.0."
    }

    assert {:error, :no_output} = Pipeline.create_plan_comment(ada, run, attrs)

    {:ok, _saved} = Pipeline.save_stage_output(task, %{markdown: "sweet_xml 0.7.5 is AGPL-3.0."})
    assert {:error, :no_output} = Pipeline.create_plan_comment(ada, plan_run, attrs)

    assert {:ok, %PlanComment{target: :output, status: :unsent, custom_stage: "License check"}} =
             Pipeline.create_plan_comment(ada, run, attrs)

    assert %{element_label: ["can't be blank"]} =
             errors_on(PlanComment.changeset(%PlanComment{}, Map.delete(attrs, :element_label)))

    {:ok, _moved} = Pipeline.update_task(task, %{stage: :review})
    assert {:error, :no_output} = Pipeline.create_plan_comment(ada, run, attrs)
  end
end
