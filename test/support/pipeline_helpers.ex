defmodule RailTest.PipelineHelpers do
  @moduledoc false

  alias RailTest.Mocks.Linear

  @doc """
  Writes an executable stub agent CLI that emits a canned NDJSON stream.
  """
  def create_chat_stub_cli(opts \\ []) do
    id = System.unique_integer([:positive])
    dir = Path.join("/tmp", "rail_stub_cli_#{id}")
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

  @doc """
  Queues `count` successful Linear file upload responses.
  """
  def mock_design_uploads(count \\ 1) do
    Enum.each(1..count, fn i ->
      Linear.mock_file_upload_success(
        upload_url: "https://api.linear.app/upload/dsg_#{i}",
        asset_url: "https://uploads.linear.app/dsg_#{i}/dir-#{i}.png",
        asset_id: "ast_dsg_#{i}"
      )
    end)
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

  def mock_qa_uploads(count \\ 1) do
    Enum.each(1..count, fn i ->
      Linear.mock_file_upload_success(
        upload_url: "https://api.linear.app/upload/qa_#{i}",
        asset_url: "https://uploads.linear.app/qa_#{i}/screenshot-#{i}.png",
        asset_id: "ast_qa_#{i}"
      )
    end)
  end
end
