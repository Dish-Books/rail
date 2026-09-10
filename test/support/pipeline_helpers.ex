defmodule RailTest.PipelineHelpers do
  @moduledoc false

  import Ecto.Query

  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Artifacts.Schemas.Design
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Repo
  alias RailTest.Mocks.Linear

  def create_test_project(attrs \\ %{}) do
    RailTest.RolesHelpers.create_test_project(attrs)
  end

  def create_test_task(attrs \\ %{}) do
    attrs = Map.new(attrs)
    id = System.unique_integer([:positive])
    project_id = attrs[:project_id] || attrs["project_id"] || create_test_project().id

    default_attrs = %{
      title: "Task #{id}",
      description: "Description for task #{id}",
      stage: :product,
      stage_state: :queued,
      worktree_name: "task-#{id}"
    }

    merged = Map.merge(default_attrs, attrs)

    %Task{}
    |> Task.changeset(merged, project_id)
    |> Repo.insert!()
  end

  def create_test_question(attrs \\ %{}) do
    attrs = Map.new(attrs)
    id = System.unique_integer([:positive])
    task_id = attrs[:task_id] || attrs["task_id"] || create_test_task().id

    default_attrs = %{
      prompt: "Question prompt #{id}?",
      options: ["Yes", "No"],
      status: :pending
    }

    merged = Map.merge(default_attrs, attrs)

    %Question{}
    |> Question.changeset(merged, task_id)
    |> Repo.insert!()
  end

  def create_test_plan(attrs \\ %{}) do
    attrs = Map.new(attrs)
    id = System.unique_integer([:positive])
    task_id = attrs[:task_id] || attrs["task_id"] || create_test_task().id

    default_attrs = %{
      content: "# Plan #{id}\nContent here",
      captured_at: DateTime.utc_now()
    }

    merged = Map.merge(default_attrs, attrs)

    %Plan{}
    |> Plan.changeset(merged, task_id)
    |> Repo.insert!()
  end

  def create_test_issue(attrs \\ %{}) do
    attrs = Map.new(attrs)
    id = System.unique_integer([:positive])
    project_id = attrs[:project_id] || attrs["project_id"] || create_test_project().id

    default_attrs = %{
      external_id: "ext_#{id}",
      identifier: "ISS-#{id}",
      title: "Issue #{id}",
      description: "Description for issue #{id}",
      state: :triage,
      branch_name: "branch-#{id}",
      url: "https://linear.app/issue/ISS-#{id}"
    }

    merged = Map.merge(default_attrs, attrs)

    %Issue{}
    |> Issue.changeset(merged, project_id)
    |> Repo.insert!()
  end

  def create_test_linear_workspace(attrs \\ %{}) do
    attrs = Map.new(attrs)
    id = System.unique_integer([:positive])

    default_attrs = %{
      name: "Linear Workspace #{id}",
      external_id: "lin_ws_#{id}",
      token: "lin_api_key_#{id}",
      webhook_secret: "secret_#{id}"
    }

    merged = Map.merge(default_attrs, attrs)

    workspace =
      %LinearWorkspace{}
      |> LinearWorkspace.changeset(merged)
      |> Repo.insert!()

    project_id = attrs[:project_id] || attrs["project_id"]

    if project_id do
      Repo.update_all(from(p in Rail.Projects.Schemas.Project, where: p.id == ^project_id),
        set: [linear_workspace_id: workspace.id]
      )
    end

    workspace
  end

  def create_test_design(attrs \\ %{}) do
    attrs = Map.new(attrs)
    id = System.unique_integer([:positive])
    task_id = attrs[:task_id] || attrs["task_id"] || create_test_task().id

    default_attrs = %{
      task_id: task_id,
      version: 1,
      canvas_url: "https://canvas.example.com/project/#{id}",
      picked_key: nil,
      directions: [
        %{
          key: "dir-1",
          title: "Direction 1",
          notes: "Notes 1",
          still_url: "https://uploads.linear.app/still_1.png"
        }
      ]
    }

    merged = Map.merge(default_attrs, attrs)

    %Design{}
    |> Design.changeset(merged)
    |> Repo.insert!()
  end

  def create_temp_scratch_dir do
    id = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "rail_scratch_test_#{id}")
    File.mkdir_p!(dir)

    ExUnit.Callbacks.on_exit(fn ->
      File.rm_rf(dir)
    end)

    dir
  end

  def mock_dispatch_hook(task, _role) do
    with {:ok, updated_task} <-
           task
           |> Task.changeset(%{stage_state: :running})
           |> Repo.update() do
      Rail.Pipeline.broadcast_pipeline_changed(%{task_id: updated_task.id, event: :dispatched})
      {:ok, updated_task}
    end
  end

  def create_chat_stub_cli(opts \\ []) do
    id = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "rail_stub_cli_#{id}")
    File.mkdir_p!(dir)

    script_path = Path.join(dir, "stub_cli.sh")
    response = Keyword.get(opts, :response, "Hello from agent")
    conversation_id = Keyword.get(opts, :conversation_id, "sess-123")
    verdict = Keyword.get(opts, :verdict)
    emit_question? = Keyword.get(opts, :emit_question, false)
    question_text = Keyword.get(opts, :question_text, "Should we use foo or bar?")
    exit_code = Keyword.get(opts, :exit_code, 0)
    touch_file = Keyword.get(opts, :touch_file)
    sleep_seconds = Keyword.get(opts, :sleep_seconds, 0)
    cost_usd = Keyword.get(opts, :cost_usd, 0.05)
    input_tokens = Keyword.get(opts, :input_tokens, 100)
    output_tokens = Keyword.get(opts, :output_tokens, 50)

    final_text = if verdict, do: "#{response}\n#{verdict}", else: response

    lines = [
      "#!/bin/sh",
      if(sleep_seconds > 0, do: "sleep #{sleep_seconds}"),
      if(touch_file, do: "echo 'modified' >> #{touch_file}"),
      "cat <<'STUB_EOF'",
      Jason.encode!(%{"type" => "system", "session_id" => conversation_id}),
      if(
        emit_question?,
        do:
          Jason.encode!(%{
            "type" => "assistant",
            "message" => %{"content" => [%{"type" => "text", "text" => "[QUESTION: #{question_text}]"}]}
          })
      ),
      Jason.encode!(%{
        "type" => "assistant",
        "message" => %{"content" => [%{"type" => "text", "text" => final_text}]}
      }),
      Jason.encode!(%{
        "type" => "result",
        "status" => if(exit_code == 0, do: "success", else: "error"),
        "usage" => %{
          "input_tokens" => input_tokens,
          "output_tokens" => output_tokens,
          "cost_usd" => cost_usd
        }
      }),
      "STUB_EOF",
      "exit #{exit_code}"
    ]

    content =
      lines
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    File.write!(script_path, content <> "\n")
    File.chmod!(script_path, 0o755)

    ExUnit.Callbacks.on_exit(fn ->
      File.rm_rf(dir)
    end)

    script_path
  end

  def create_test_design_dir(opts \\ []) do
    worktree_dir = create_temp_scratch_dir()
    design_dir = Path.join([worktree_dir, ".axis", "design"])
    File.mkdir_p!(design_dir)

    canvas_url = Keyword.get(opts, :canvas_url, "https://claude.ai/design/canvas-1")
    version = Keyword.get(opts, :version, 1)
    picked_key = Keyword.get(opts, :picked_key)

    still_1 = Path.join(design_dir, "dir-1.png")
    File.write!(still_1, "fake png content 1")
    still_2 = Path.join(design_dir, "dir-2.png")
    File.write!(still_2, "fake png content 2")

    default_directions = [
      %{
        "key" => "dir-1",
        "title" => "Minimal Light",
        "notes" => "Clean aesthetic with spacious white layout",
        "stillPath" => ".axis/design/dir-1.png"
      },
      %{
        "key" => "dir-2",
        "title" => "Bold Dark",
        "notes" => "Dark mode with high contrast neon highlights",
        "stillPath" => ".axis/design/dir-2.png"
      }
    ]

    directions = Keyword.get(opts, :directions, default_directions)

    manifest_content =
      Keyword.get(opts, :raw_manifest) ||
        Jason.encode!(%{
          "canvasUrl" => canvas_url,
          "version" => version,
          "pickedKey" => picked_key,
          "directions" => directions
        })

    File.write!(Path.join(design_dir, "manifest.json"), manifest_content)
    worktree_dir
  end

  def mock_design_uploads(count \\ 1) do
    Enum.each(1..count, fn i ->
      Linear.mock_file_upload_success(
        upload_url: "https://api.linear.app/upload/dsg_#{i}",
        asset_url: "https://uploads.linear.app/dsg_#{i}/dir-#{i}.png",
        asset_id: "ast_dsg_#{i}"
      )
    end)
  end

  def create_test_demo(attrs \\ %{}) do
    attrs = Map.new(attrs)
    id = System.unique_integer([:positive])
    task_id = attrs[:task_id] || attrs["task_id"] || create_test_task().id

    default_attrs = %{
      task_id: task_id,
      version: 1,
      recorded_at: DateTime.utc_now(),
      commit: "commit_#{id}",
      head_sha: "head_#{id}",
      dirty_digest: "digest_#{id}",
      outcome: "recorded",
      note: nil,
      stale: false,
      segments: [
        %{
          criterion_index: 1,
          criterion: "Feature works as expected",
          outcome: :recorded,
          note: nil,
          frames: [
            %{
              path: "frame_1.png",
              resolved_path: "/tmp/frame_1.png",
              url: "https://uploads.linear.app/demo_#{id}/frame_1.png",
              linear_asset_id: "ast_demo_#{id}",
              hold_ms: 1000,
              caption: "Initial state",
              size: 1024
            }
          ]
        }
      ]
    }

    merged = Map.merge(default_attrs, attrs)

    %Demo{}
    |> Demo.changeset(merged)
    |> Repo.insert!()
  end

  def create_test_demo_dir(opts \\ []) do
    worktree_dir = create_temp_scratch_dir()
    sub_path = Keyword.get(opts, :sub_path, [".axis", "demo"])
    demo_dir = Path.join([worktree_dir | List.wrap(sub_path)])
    File.mkdir_p!(demo_dir)

    version = Keyword.get(opts, :version, 1)
    outcome = Keyword.get(opts, :outcome, "recorded")
    note = Keyword.get(opts, :note)

    frame_1 = Path.join(demo_dir, "frame-1.png")
    File.write!(frame_1, "fake demo frame content 1")

    default_segments = [
      %{
        "criterionIndex" => 1,
        "criterion" => Keyword.get(opts, :criterion, "Feature works as expected"),
        "outcome" => "recorded",
        "frames" => [
          %{
            "path" => Path.relative_to(frame_1, demo_dir),
            "holdMs" => 1000,
            "caption" => "Step 1"
          }
        ]
      }
    ]

    segments =
      case outcome do
        "recorded" -> Keyword.get(opts, :segments, default_segments)
        _declined_or_failed -> Keyword.get(opts, :segments, [])
      end

    manifest_map = %{
      "version" => version,
      "outcome" => outcome,
      "note" => note,
      "segments" => segments
    }

    manifest_content =
      Keyword.get(opts, :raw_manifest) || Jason.encode!(manifest_map)

    File.write!(Path.join(demo_dir, "manifest.json"), manifest_content)
    worktree_dir
  end

  def mock_demo_uploads(count \\ 1) do
    Enum.each(1..count, fn i ->
      Linear.mock_file_upload_success(
        upload_url: "https://api.linear.app/upload/dmo_#{i}",
        asset_url: "https://uploads.linear.app/dmo_#{i}/frame-#{i}.png",
        asset_id: "ast_dmo_#{i}"
      )
    end)
  end
end
