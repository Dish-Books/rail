defmodule Rail.Pipeline.Workers.NotifyOwnerTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Workers.NotifyOwner
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Scope
  alias Rail.Slack
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup %{project: project} do
    unique = System.unique_integer([:positive])

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_no_#{unique}", "identifier" => "NO-#{unique}", "title" => "Pick <one> & go"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Pick <one> & go"})
    {:ok, task} = Pipeline.create_task(issue, :plan)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, owner} =
      Users.register_oauth_user(%{github_id: "no_#{unique}", login: "no_#{unique}", email: "no_#{unique}@example.com"})

    team_id = "T#{unique}"

    {:ok, owner} =
      Users.update_user(system_scope(), owner, %{name: "Maya Kowalski", slack_user_id: "U_MAYA", slack_team_id: team_id})

    {:ok, owner} = Users.set_slack_notifications(Scope.for_user(owner), true)
    Repo.update_all(from(i in Issue, where: i.id == ^issue.id), set: [owner_user_id: owner.id])

    Req.Test.expect(Slack, &Req.Test.json(&1, %{"ok" => true, "team_id" => team_id}))
    {:ok, _workspace} = Projects.create_slack_workspace(system_scope(), %{"name" => "Acme", "token" => "xoxb-bot"})

    roles =
      Map.new([:plan, :engineer, :qa, :review_lead], fn stage ->
        {:ok, role} = Roles.get_role(project_id: project.id, stage: stage)
        {stage, role}
      end)

    run = fn stage, attrs ->
      {:ok, run} =
        Pipeline.create_run(
          Map.merge(
            %{task_id: task.id, role_id: roles[stage].id, status: :finished, started_at: DateTime.utc_now()},
            attrs
          )
        )

      run
    end

    test_pid = self()

    # Every message Slack is sent comes back to the test as the channel and text it was sent with.
    posted = fn ->
      Req.Test.expect(Slack, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert "/api/chat.postMessage" = conn.request_path
        assert ["Bearer xoxb-bot"] = Plug.Conn.get_req_header(conn, "authorization")
        send(test_pid, {:posted, Jason.decode!(body)})
        Req.Test.json(conn, %{"ok" => true, "ts" => "1790000000.000100"})
      end)
    end

    %{task: task, issue: issue, owner: owner, run: run, posted: posted, unique: unique}
  end

  describe "a turn that left the task waiting" do
    test "with three questions posts one message to the owner naming the task and linking to it", %{
      task: task,
      run: run,
      posted: posted,
      unique: unique
    } do
      %Run{id: run_id} = run.(:plan, %{status: :blocked_on_input})

      for prompt <- ["Which database?", "Ship behind a flag?", "Keep the old table?"] do
        Repo.insert!(%Question{task_id: task.id, run_id: run_id, prompt: prompt, status: :pending})
      end

      posted.()
      assert :ok = perform_job(NotifyOwner, %{run_id: run_id, os_process_id: "osp_1"})

      expected =
        "<#{RailWeb.Endpoint.url()}/tasks/#{task.id}|NO-#{unique} Pick &lt;one&gt; &amp; go>\n" <>
          "Plan has *3 questions* for you."

      assert_received {:posted, %{"channel" => "U_MAYA", "text" => ^expected}}
    end

    test "with one question, or answers not yet sent, says so", %{task: task, run: run, posted: posted} do
      %Run{id: run_id} = run.(:plan, %{status: :blocked_on_input})
      question = Repo.insert!(%Question{task_id: task.id, run_id: run_id, prompt: "Which?", status: :pending})

      posted.()
      assert :ok = perform_job(NotifyOwner, %{run_id: run_id, os_process_id: "osp_1"})
      assert_received {:posted, %{"text" => text}}
      assert text =~ "\nPlan has *a question* for you."

      question |> Ecto.Changeset.change(status: :answered, answer: "This one") |> Repo.update!()
      posted.()
      assert :ok = perform_job(NotifyOwner, %{run_id: run_id, os_process_id: "osp_2"})
      assert_received {:posted, %{"text" => text}}
      assert text =~ "\nPlan needs an answer from you."
    end

    test "after Rail sent the round back itself posts nothing", %{task: task, run: run} do
      %Run{id: run_id} = run.(:plan, %{status: :running})

      Repo.insert!(%Question{
        task_id: task.id,
        run_id: run_id,
        prompt: "Which database?",
        status: :answered,
        answer: "Postgres.",
        answered_by_rail: true,
        delivered_at: DateTime.utc_now()
      })

      assert :ok = perform_job(NotifyOwner, %{run_id: run_id, os_process_id: "osp_1"})
    end

    test "that failed gives the first line of its error", %{run: run, posted: posted} do
      %Run{id: run_id} = run.(:plan, %{error: "\nThe sandbox ran out of <memory>.\nKilled at 4 GB."})

      posted.()
      assert :ok = perform_job(NotifyOwner, %{run_id: run_id, os_process_id: "osp_1"})
      assert_received {:posted, %{"text" => text}}
      assert text =~ "\nPlan failed: The sandbox ran out of &lt;memory&gt;."
      refute text =~ "Killed"
    end

    test "says what a finished stage waits on", %{task: task, issue: issue, run: run, posted: posted} do
      %Run{id: plan_id} = run.(:plan, %{stage_outcome: :done})

      posted.()
      assert :ok = perform_job(NotifyOwner, %{run_id: plan_id, os_process_id: "osp_1"})
      assert_received {:posted, %{"text" => text}}
      assert text =~ "\nThe plan is ready for you to review."

      issue |> Repo.reload!() |> Ecto.Changeset.change(skipped_steps: [:architect]) |> Repo.update!()
      posted.()
      assert :ok = perform_job(NotifyOwner, %{run_id: plan_id, os_process_id: "osp_2"})
      assert_received {:posted, %{"text" => text}}
      assert text =~ "\nThe ticket is ready for you to review."

      design = Path.join(task.scratch_path, "design")
      File.mkdir_p!(design)
      manifest = ~s({"options": [{"key": "cards", "title": "Cards"}, {"key": "table", "title": "Table"}]})
      File.write!(Path.join(design, "manifest.json"), manifest)
      posted.()
      assert :ok = perform_job(NotifyOwner, %{run_id: plan_id, os_process_id: "osp_3"})
      assert_received {:posted, %{"text" => text}}
      assert text =~ "\nPick a design."

      {:ok, task} = Pipeline.update_task(task, %{stage: :engineer})
      %Run{id: engineer_id} = run.(:engineer, %{stage_outcome: :done})
      posted.()
      assert :ok = perform_job(NotifyOwner, %{run_id: engineer_id, os_process_id: "osp_4"})
      assert_received {:posted, %{"text" => text}}
      assert text =~ "\nThe diff is ready for you to review."

      {:ok, task} = Pipeline.update_task(task, %{stage: :review})
      %Run{id: lead_id} = run.(:review_lead, %{stage_outcome: :done})
      posted.()
      assert :ok = perform_job(NotifyOwner, %{run_id: lead_id, os_process_id: "osp_5"})
      assert_received {:posted, %{"text" => text}}
      assert text =~ "\nReview is waiting on you."

      for {key, count} <- [{"one", 1}, {"two", 2}] do
        Repo.insert!(%Finding{
          task_id: task.id,
          key: key,
          kind: :code,
          raised_by: :code_reviewer,
          round: 1,
          title: "Finding #{key}",
          file: "lib/a.ex",
          line: 1,
          severity: :nit,
          recommendation: :fix
        })

        posted.()
        assert :ok = perform_job(NotifyOwner, %{run_id: lead_id, os_process_id: "osp_findings_#{count}"})
        assert_received {:posted, %{"text" => text}}

        assert text =~
                 if(count == 1,
                   do: "\nReview finished with *1 finding* for you to rule on.",
                   else: "\nReview finished with *2 findings* for you to rule on."
                 )
      end

      {:ok, _task} = Pipeline.update_task(task, %{stage: :finalize})
      posted.()
      assert :ok = perform_job(NotifyOwner, %{run_id: lead_id, os_process_id: "osp_6"})
      assert_received {:posted, %{"text" => text}}
      assert text =~ "\nReady to finalize."
    end

    test "posts nothing for a run the stage has moved on from", %{run: run, posted: posted} do
      %Run{id: earlier_id} =
        run.(:plan, %{stage_outcome: :done, started_at: DateTime.shift(DateTime.utc_now(), minute: -5)})

      %Run{id: later_id} = run.(:plan, %{stage_outcome: :done})

      assert :ok = perform_job(NotifyOwner, %{run_id: earlier_id, os_process_id: "osp_1"})

      posted.()
      assert :ok = perform_job(NotifyOwner, %{run_id: later_id, os_process_id: "osp_2"})
      assert_received {:posted, %{"text" => _text}}
    end

    test "posts nothing once the run is gone", %{run: run} do
      %Run{id: run_id} = gone = run.(:plan, %{stage_outcome: :done})
      Repo.delete!(gone)

      assert :ok = perform_job(NotifyOwner, %{run_id: run_id, os_process_id: "osp_1"})
    end
  end

  describe "the owner" do
    test "with notifications off gets nothing", %{owner: owner, run: run, posted: posted} do
      %Run{id: run_id} = run.(:plan, %{stage_outcome: :done})

      {:ok, _off} = Users.set_slack_notifications(Scope.for_user(owner), false)
      assert :ok = perform_job(NotifyOwner, %{run_id: run_id, os_process_id: "osp_1"})

      {:ok, _on} = Users.set_slack_notifications(Scope.for_user(owner), true)
      posted.()
      assert :ok = perform_job(NotifyOwner, %{run_id: run_id, os_process_id: "osp_2"})
      assert_received {:posted, %{"channel" => "U_MAYA"}}
    end

    test "who disconnected Slack gets nothing, and connecting again does not turn them back on", %{
      owner: owner,
      run: run,
      unique: unique
    } do
      %Run{id: run_id} = run.(:plan, %{stage_outcome: :done})

      {:ok, _unlinked} = Users.unlink_slack(Scope.for_user(owner))
      assert :ok = perform_job(NotifyOwner, %{run_id: run_id, os_process_id: "osp_1"})

      {:ok, relinked} =
        Users.update_user(system_scope(), Repo.reload!(owner), %{slack_user_id: "U_MAYA", slack_team_id: "T#{unique}"})

      assert %User{slack_notifications: false} = relinked
      assert :ok = perform_job(NotifyOwner, %{run_id: run_id, os_process_id: "osp_2"})
    end

    test "whose Slack team Rail has no workspace for gets nothing", %{owner: owner, run: run} do
      %Run{id: run_id} = run.(:plan, %{stage_outcome: :done})
      {:ok, _moved} = Users.update_user(system_scope(), owner, %{slack_team_id: "T_ELSEWHERE"})

      assert :ok = perform_job(NotifyOwner, %{run_id: run_id, os_process_id: "osp_1"})
    end

    test "of nobody means nobody is messaged", %{issue: issue, run: run} do
      %Run{id: run_id} = run.(:plan, %{stage_outcome: :done})
      Repo.update_all(from(i in Issue, where: i.id == ^issue.id), set: [owner_user_id: nil])

      assert :ok = perform_job(NotifyOwner, %{run_id: run_id, os_process_id: "osp_1"})
    end
  end

  describe "a merge" do
    setup %{task: task} do
      {:ok, task} = Pipeline.update_task(task, %{stage: :merged, merged_at: DateTime.utc_now()})
      %{task: task}
    end

    test "by someone else says who merged it", %{task: task, posted: posted, unique: unique} do
      {:ok, dev} =
        Users.register_oauth_user(%{
          github_id: "dev_#{unique}",
          login: "dev_#{unique}",
          email: "dev_#{unique}@example.com"
        })

      {:ok, _dev} = Users.update_user(system_scope(), dev, %{name: "Dev Patel"})
      {:ok, task} = Pipeline.update_task(task, %{merged_by_id: dev.id})

      posted.()
      assert :ok = perform_job(NotifyOwner, %{task_id: task.id})
      assert_received {:posted, %{"channel" => "U_MAYA", "text" => text}}
      assert text =~ "\nMerged by Dev Patel."
    end

    test "on GitHub by someone Rail does not know says so", %{task: task, posted: posted} do
      posted.()
      assert :ok = perform_job(NotifyOwner, %{task_id: task.id})
      assert_received {:posted, %{"text" => text}}
      assert text =~ "\nMerged on GitHub."
    end

    test "by the owner posts nothing", %{task: task, owner: owner} do
      {:ok, task} = Pipeline.update_task(task, %{merged_by_id: owner.id})

      assert :ok = perform_job(NotifyOwner, %{task_id: task.id})
    end
  end
end
