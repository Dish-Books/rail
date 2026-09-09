defmodule RailTest.PipelineHelpers do
  @moduledoc false

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

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
end
