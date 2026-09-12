defmodule Rail.Runs.Actions.BuildArgsTest do
  use Rail.DataCase, async: true

  alias Rail.Backends.Schemas.Backend
  alias Rail.Runs

  test "builds standard Claude args in exact flag order" do
    opts = [
      backend: %Backend{name: :claude},
      prompt: "Fix the bug",
      model: "claude-3-7-sonnet-20250219",
      effort: "high"
    ]

    args = Runs.build_args(opts)

    assert args == [
             "-p",
             "Fix the bug",
             "--model",
             "claude-3-7-sonnet-20250219",
             "--effort",
             "high",
             "--dangerously-skip-permissions",
             "--output-format",
             "stream-json",
             "--verbose"
           ]
  end

  test "builds read-only Claude args with tools empty string and strict mcp config" do
    opts = %{
      backend: %Backend{name: :claude},
      prompt: "Review the code",
      model: "claude-3-5-sonnet-20241022",
      effort: "medium",
      read_only: true
    }

    args = Runs.build_args(opts)

    assert args == [
             "-p",
             "Review the code",
             "--model",
             "claude-3-5-sonnet-20241022",
             "--effort",
             "medium",
             "--tools",
             "",
             "--strict-mcp-config",
             "--output-format",
             "stream-json",
             "--verbose"
           ]

    refute "--dangerously-skip-permissions" in args
  end

  test "attaches --system-prompt and --resume to Claude args when present" do
    opts = [
      backend: %Backend{name: :claude},
      prompt: "Do work",
      model: "claude-3-7-sonnet",
      system_prompt: "Act as QA engineer.",
      conversation_id: "sess-abc-123"
    ]

    args = Runs.build_args(opts)

    assert Enum.take(args, -4) == [
             "--system-prompt",
             "Act as QA engineer.",
             "--resume",
             "sess-abc-123"
           ]
  end

  test "omits empty system-prompt and resume from Claude args" do
    opts = [
      backend: %Backend{name: :claude},
      prompt: "Run",
      model: "claude-3-7-sonnet",
      system_prompt: "   ",
      conversation_id: nil
    ]

    args = Runs.build_args(opts)

    refute "--system-prompt" in args
    refute "--resume" in args
  end

  test "builds standard Agy args in exact flag order" do
    opts = [
      backend: %Backend{name: :agy},
      prompt: "Refactor auth",
      model: "gemini-2.5-pro",
      effort: "high",
      work_dir: "/Users/michael/Code/rail/.worktrees/task-1",
      log_file: "/tmp/rail/agy-logs/task-1.log"
    ]

    args = Runs.build_args(opts)

    assert args == [
             "-p",
             "Refactor auth",
             "--model",
             "gemini-2.5-pro",
             "--effort",
             "high",
             "--dangerously-skip-permissions",
             "--mode",
             "accept-edits",
             "--output-format",
             "stream-json",
             "--print-timeout",
             "6h",
             "--add-dir",
             "/Users/michael/Code/rail/.worktrees/task-1",
             "--log-file",
             "/tmp/rail/agy-logs/task-1.log"
           ]
  end

  test "builds read-only Agy args with mode plan and no skip-permissions" do
    opts = %{
      backend: %Backend{name: :agy},
      prompt: "Plan the feature",
      model: "gemini-2.5-flash",
      reasoning_effort: "low",
      read_only: true,
      print_timeout: "2h"
    }

    args = Runs.build_args(opts)

    assert args == [
             "-p",
             "Plan the feature",
             "--model",
             "gemini-2.5-flash",
             "--effort",
             "low",
             "--mode",
             "plan",
             "--output-format",
             "stream-json",
             "--print-timeout",
             "2h"
           ]

    refute "--dangerously-skip-permissions" in args
    refute "--add-dir" in args
    refute "--log-file" in args
  end

  test "attaches --conversation for Agy resume turn" do
    opts = [
      backend: %Backend{name: :agy},
      prompt: "Continue",
      model: "gemini-2.5-pro",
      conversation_id: "conv-xyz-789"
    ]

    args = Runs.build_args(opts)

    assert Enum.take(args, -2) == ["--conversation", "conv-xyz-789"]
    refute "--resume" in args
    refute "--system-prompt" in args
    refute "--verbose" in args
  end

  test "treats non-claude backend as Agy" do
    opts = [
      backend: "unknown-engine",
      prompt: "Fallback run",
      model: "default-model"
    ]

    args = Runs.build_args(opts)

    assert "--mode" in args
    assert "--print-timeout" in args

    nil_args = Runs.build_args(backend: nil, prompt: "Nil engine")
    assert "--mode" in nil_args

    int_args = Runs.build_args(backend: 123, prompt: "Int engine")
    assert "--mode" in int_args
  end

  test "ignores whitespace in agy add_dir, log_file, and conversation" do
    opts = [
      backend: %Backend{name: :agy},
      prompt: "Terse",
      model: "gemini",
      work_dir: "   ",
      log_file: "   ",
      conversation_id: "   "
    ]

    args = Runs.build_args(opts)
    refute "--add-dir" in args
    refute "--log-file" in args
    refute "--conversation" in args
  end
end
