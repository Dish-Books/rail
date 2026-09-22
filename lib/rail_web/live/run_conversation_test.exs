defmodule RailWeb.Live.RunConversationTest do
  use Rail.DataCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools.Schemas.OsProcess
  alias RailWeb.Live.RunConversation

  setup do
    scope = system_scope()

    {:ok, backend} = Rail.Tools.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Conversation Project",
        github_repo: "org/conversation",
        github_installation_id: 22_101,
        linear_workspace: %{
          name: "Conversation Workspace",
          external_id: "lin_ws_conversation",
          token: "lin_api_token_conversation",
          webhook_secret: "whsec_conversation"
        },
        linear_team_key: "CNV",
        default_branch: "main",
        clone_path: "/tmp/repos/conversation",
        linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"}
      })

    roles =
      Map.new([:architect, :engineer], fn stage ->
        {:ok, role} =
          Roles.create_role(scope, project, %{
            backend_id: backend.id,
            stage: stage,
            name: String.capitalize(to_string(stage)),
            model: "claude-3-7-sonnet",
            system_prompt: "You are the #{stage} agent.",
            icon_name: "pi-code"
          })

        {stage, role}
      end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_conversation_1",
              "identifier" => "CNV-1",
              "title" => "Conversation Issue"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Conversation Issue"})
    {:ok, task} = Pipeline.create_task(issue, :product)
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer})

    roles_map = Map.new(roles, fn {_stage, role} -> {role.id, role} end)

    %{project: project, task: task, roles: roles, roles_map: roles_map}
  end

  test "says so when the role on the tab has not run the task", %{task: task, roles_map: roles_map} do
    html = render_component(RunConversation, id: "conv", task: task, runs: [], roles_map: roles_map)

    assert html =~ ~s(data-qa="conversation_empty_state")
    assert html =~ "This role has not run on the task yet."
  end

  test "names the role being read and describes its run", %{task: task, roles: roles, roles_map: roles_map} do
    {:ok, architect} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:architect].id,
        status: :finished,
        started_at: ~U[2026-09-09 09:00:00.000000Z],
        completed_at: ~U[2026-09-09 09:05:00.000000Z]
      })

    {:ok, engineer} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        conversation_id: "conv_engineer",
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })

    html =
      render_component(RunConversation,
        id: "conv",
        task: task,
        runs: [architect, engineer],
        roles_map: roles_map
      )

    # The most recent run is the one being read.
    assert html =~ ~s(id="conversation-role-#{engineer.role_id}")
    refute html =~ ~s(id="conversation-role-#{architect.role_id}")
    assert html =~ "running"
    assert html =~ "conversation conv_engineer"
  end

  test "renders each kind of thing said in the conversation", %{task: task, roles: roles, roles_map: roles_map} do
    {:ok, architect} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:architect].id,
        status: :finished,
        started_at: ~U[2026-09-09 09:00:00.000000Z]
      })

    {:ok, engineer} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        conversation_id: "conv_engineer",
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })

    Pipeline.append_run_events(
      engineer.id,
      nil,
      [
        "[human] Please implement the OAuth callback handler",
        "[run] Runner started execution",
        "I will start by reviewing the router.",
        "[tool read_file] lib/rail_web/router.ex",
        "[tool read_file] lib/rail_web/user_auth.ex",
        "Follow the schema plan closely.",
        "[rail] Automated check completed"
      ]
    )

    html =
      render_component(RunConversation,
        id: "conv",
        task: task,
        runs: [architect, engineer],
        roles_map: roles_map
      )

    assert html =~ ~s(data-qa="human-bubble")
    assert html =~ "Please implement the OAuth callback handler"
    assert html =~ ~s(data-qa="role-bubble")
    assert html =~ "I will start by reviewing the router."
    assert html =~ ~s(data-qa="activity-tile")
    assert html =~ "Tool activity (2 steps)"
    refute html =~ ~s(data-qa="activity-content")
    assert html =~ ~s(data-qa="rail-event")
    assert html =~ ~s(data-qa="system-event")
  end

  test "reads the agent's stream as a conversation, not as JSON", %{task: task, roles: roles, roles_map: roles_map} do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        conversation_id: "conv_stream",
        started_at: ~U[2026-09-09 10:00:00.000000Z],
        completed_at: ~U[2026-09-09 10:01:05.000000Z]
      })

    Pipeline.append_run_events(run.id, nil, [
      ~s({"type":"system","subtype":"init","session_id":"conv_stream","tools":[]}),
      ~s({"type":"assistant","message":{"content":[{"type":"text","text":"## Plan\\n\\n- **One** step"}]}}),
      ~s({"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/repo/a.ex"}}]}}),
      "[human] Looks good"
    ])

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    refute html =~ "&quot;type&quot;"
    assert html =~ "<strong>One</strong>"
    assert html =~ "Tool activity (1 step)"
    assert html =~ "Looks good"
  end

  # The run's own started_at is reset by every turn, so the figure a reader wants
  # is the turns added up, not the last one.
  test "the elapsed time is every turn the agent took, added up", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        started_at: ~U[2026-09-09 10:30:00.000000Z],
        completed_at: ~U[2026-09-09 10:30:20.000000Z]
      })

    for {started, ended} <- [
          {~U[2026-09-09 10:00:00.000000Z], ~U[2026-09-09 10:01:05.000000Z]},
          {~U[2026-09-09 10:30:00.000000Z], ~U[2026-09-09 10:30:20.000000Z]}
        ] do
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        stream_path: "/tmp/#{run.id}.ndjson",
        status: :finished,
        started_at: started
      })
      |> Repo.insert!()
      |> Ecto.Changeset.change(updated_at: ended)
      |> Repo.update!()
    end

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert html =~ ~s(data-elapsed-seconds="85")
    assert html =~ "1m 25s"
    refute html =~ "data-started-at"
  end

  test "a turn still running keeps counting in the browser", %{task: task, roles: roles, roles_map: roles_map} do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        started_at: ~U[2026-09-09 10:30:00.000000Z]
      })

    %OsProcess{}
    |> OsProcess.changeset(%{
      run_id: run.id,
      task_id: task.id,
      stream_path: "/tmp/#{run.id}.ndjson",
      status: :running,
      started_at: ~U[2026-09-09 10:30:00.000000Z]
    })
    |> Repo.insert!()

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert html =~ ~s(data-started-at="2026-09-09T10:30:00.000000Z")
    assert html =~ ~s(data-elapsed-seconds="0")
  end

  test "each turn is marked in the transcript with when it started and what it cost", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })

    first =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        stream_path: "/tmp/#{run.id}.ndjson",
        status: :finished,
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })
      |> Repo.insert!()
      |> Ecto.Changeset.change(updated_at: ~U[2026-09-09 10:00:30.000000Z])
      |> Repo.update!()

    second =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        stream_path: "/tmp/#{run.id}.ndjson",
        status: :finished,
        started_at: ~U[2026-09-09 11:00:00.000000Z]
      })
      |> Repo.insert!()
      |> Ecto.Changeset.change(updated_at: ~U[2026-09-09 11:02:00.000000Z])
      |> Repo.update!()

    Pipeline.append_run_events(run.id, first.id, ["[rail] the first turn", "[rail] still the first turn"])
    Pipeline.append_run_events(run.id, second.id, ["[rail] the second turn"])

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert html =~ ~s(data-qa="turn-start")
    assert html =~ "Turn 1"
    assert html =~ "Turn 2"
    assert html =~ "30s"
    assert html =~ "2m 0s"
    assert html =~ ~s(data-at="2026-09-09T11:00:00.000000Z")
    assert html =~ "still the first turn"
  end

  test "a setup script reads as its output in one block, not as a turn of the agent's", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :failed,
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })

    setup =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        kind: :setup,
        command: "./scripts/setup-worktree.sh",
        exit_code: 1,
        stream_path: "/tmp/#{run.id}.log",
        status: :finished,
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })
      |> Repo.insert!()

    Pipeline.append_run_events(run.id, setup.id, ["Worktree slot \e[1m3\e[0m", "Cannot copy dishbooks_dev"])
    Pipeline.append_run_events(run.id, nil, ["[rail] the stage was not entered"])

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    refute html =~ ~s(data-qa="turn-start")
    assert html =~ ~s(data-qa="command-block")
    assert html =~ "./scripts/setup-worktree.sh"
    assert html =~ "Failed · exit 1"
    assert html =~ "Worktree slot 3\nCannot copy dishbooks_dev"
    assert html =~ ~s(data-qa="rail-event")
  end

  test "a setup script that passed keeps its output folded away until asked", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })

    setup =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        kind: :setup,
        command: "./bin/setup",
        exit_code: 0,
        stream_path: "/tmp/#{run.id}.log",
        status: :finished,
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })
      |> Repo.insert!()

    Pipeline.append_run_events(run.id, setup.id, ["all set"])

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert html =~ "Passed"
    refute html =~ ~s(data-qa="command-output")
  end

  test "a setup script says whether it is still going or was stopped", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })

    for {status, exit_code, line} <- [{:finished, -1, "was stopped"}, {:running, nil, "still copying"}] do
      setup =
        %OsProcess{}
        |> OsProcess.changeset(%{
          run_id: run.id,
          task_id: task.id,
          kind: :setup,
          command: "./bin/setup",
          exit_code: exit_code,
          stream_path: "/tmp/#{run.id}-#{status}.log",
          status: status,
          started_at: ~U[2026-09-09 10:00:00.000000Z]
        })
        |> Repo.insert!()

      Pipeline.append_run_events(run.id, setup.id, [line])
    end

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert html =~ "Stopped"
    assert html =~ "Running"
    assert html =~ "still copying"
  end

  # The page's tab says which run is being read, and a role whose turn has not
  # come has nothing to show rather than somebody else's transcript.
  test "a tab whose role has not run reads as nothing, not as the last run", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })

    Pipeline.append_run_events(run.id, nil, ["Plain words from the agent."])

    html =
      render_component(RunConversation,
        id: "conv",
        task: task,
        runs: [run],
        roles_map: roles_map,
        stage_run: nil
      )

    refute html =~ "Plain words from the agent."
  end

  test "tool activity names each step, reads paths from the worktree root and flags errors", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: "/work/tree"})

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        conversation_id: "conv_tools",
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })

    Pipeline.append_run_events(run.id, nil, [
      "[tool] Read /work/tree/lib/rail.ex",
      "[tool] Bash mix test",
      "[tool] Read /work/tree/lib/rail_web.ex",
      "[tool error] File not found"
    ])

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert html =~ "Tool activity (4 steps)"
    assert html =~ "Read ×2, Bash"
    assert html =~ "pi-warning-circle"
  end

  test "the composer says the agent is thinking, and offers to stop it", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        conversation_id: "conv_thinking",
        started_at: DateTime.utc_now()
      })

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert html =~ ~s(id="thinking-banner")
    assert html =~ ~s(id="stop-run")
    refute html =~ ~s(id="queued-banner")
  end

  test "a message waiting on a working agent stacks under the thinking banner", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :running,
        conversation_id: "conv_queued",
        pending_chat: "Please add a test",
        started_at: DateTime.utc_now()
      })

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert html =~ ~s(id="thinking-banner")
    assert html =~ ~s(id="queued-banner")
    assert html =~ ~s(id="send-queued-now")
    assert html =~ "Please add a test"
  end

  test "a run whose role is unknown still reads, with what it spent", %{task: task, roles: roles} do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        conversation_id: "conv_unknown_role",
        usage: %{input_tokens: 1200, output_tokens: 300},
        started_at: ~U[2026-09-09 10:00:00.000000Z]
      })

    Pipeline.append_run_events(run.id, nil, ["Plain words from the agent."])

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: %{})

    assert html =~ ~s(id="metadata-run-usage")
    assert html =~ "Plain words from the agent."
    assert html =~ ~s(id="conversation-role-#{run.role_id}")
  end

  test "a run with no conversation cannot be chatted with, but its stage can be retried", %{
    task: task,
    roles: roles,
    roles_map: roles_map
  } do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert html =~ ~s(id="unavailable-banner")
    assert html =~ "has not started a conversation"
    assert html =~ ~s(id="retry-run")

    # A stage the task has left is not entered again from here.
    {:ok, planning} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:architect].id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    html = render_component(RunConversation, id: "conv", task: task, runs: [planning], roles_map: roles_map)

    assert html =~ ~s(id="unavailable-banner")
    refute html =~ ~s(id="retry-run")
  end

  test "a run that failed says why in the conversation", %{task: task, roles: roles, roles_map: roles_map} do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        error: "claude reported error_during_execution: Eligibility check failed",
        started_at: DateTime.utc_now()
      })

    Pipeline.append_run_events(run.id, nil, [
      ~s({"type":"result","subtype":"error_during_execution","is_error":true,"result":"Eligibility check failed"})
    ])

    html = render_component(RunConversation, id: "conv", task: task, runs: [run], roles_map: roles_map)

    assert html =~ ~s(data-qa="error-event")
    assert html =~ "claude reported error_during_execution: Eligibility check failed"

    # A result that spent nothing says only its status, with no dangling separator.
    assert html =~ ~r/\[result\] error_during_execution\s*</
  end
end
