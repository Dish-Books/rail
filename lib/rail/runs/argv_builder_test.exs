defmodule Rail.Runs.ArgvBuilderTest do
  use Rail.DataCase, async: true

  alias Rail.Runs.ArgvBuilder

  test "builds standard Claude argv in exact flag order" do
    opts = [
      backend: :claude,
      prompt: "Fix the bug",
      model: "claude-3-7-sonnet-20250219",
      effort: "high"
    ]

    argv = ArgvBuilder.build_argv(opts)

    assert argv == [
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

  test "builds read-only Claude argv with tools empty string and strict mcp config" do
    opts = %{
      backend: "claude",
      prompt: "Review the code",
      model: "claude-3-5-sonnet-20241022",
      effort: "medium",
      read_only: true
    }

    argv = ArgvBuilder.build_argv(opts)

    assert argv == [
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

    refute "--dangerously-skip-permissions" in argv
  end

  test "attaches --system-prompt and --resume to Claude argv when present" do
    opts = [
      backend: "CLAUDE",
      prompt: "Do work",
      model: "claude-3-7-sonnet",
      system_prompt: "Act as QA engineer.",
      conversation_id: "sess-abc-123"
    ]

    argv = ArgvBuilder.build_argv(opts)

    assert Enum.take(argv, -4) == [
             "--system-prompt",
             "Act as QA engineer.",
             "--resume",
             "sess-abc-123"
           ]
  end

  test "omits empty system-prompt and resume from Claude argv" do
    opts = [
      backend: :claude,
      prompt: "Run",
      model: "claude-3-7-sonnet",
      system_prompt: "   ",
      conversation_id: nil
    ]

    argv = ArgvBuilder.build_argv(opts)

    refute "--system-prompt" in argv
    refute "--resume" in argv
  end

  test "builds standard Agy argv in exact flag order" do
    opts = [
      backend: :agy,
      prompt: "Refactor auth",
      model: "gemini-2.5-pro",
      effort: "high",
      work_dir: "/Users/michael/Code/rail/.worktrees/task-1",
      log_file: "/tmp/rail/agy-logs/task-1.log"
    ]

    argv = ArgvBuilder.build_argv(opts)

    assert argv == [
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

  test "builds read-only Agy argv with mode plan and no skip-permissions" do
    opts = %{
      backend: "agy",
      prompt: "Plan the feature",
      model: "gemini-2.5-flash",
      reasoning_effort: "low",
      read_only: true,
      print_timeout: "2h"
    }

    argv = ArgvBuilder.build_argv(opts)

    assert argv == [
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

    refute "--dangerously-skip-permissions" in argv
    refute "--add-dir" in argv
    refute "--log-file" in argv
  end

  test "attaches --conversation for Agy resume turn" do
    opts = [
      backend: :agy,
      prompt: "Continue",
      model: "gemini-2.5-pro",
      conversation_id: "conv-xyz-789"
    ]

    argv = ArgvBuilder.build_argv(opts)

    assert Enum.take(argv, -2) == ["--conversation", "conv-xyz-789"]
    refute "--resume" in argv
    refute "--system-prompt" in argv
    refute "--verbose" in argv
  end

  test "treats non-claude backend as Agy" do
    opts = [
      backend: "unknown-engine",
      prompt: "Fallback run",
      model: "default-model"
    ]

    argv = ArgvBuilder.build_argv(opts)

    assert "--mode" in argv
    assert "--print-timeout" in argv

    nil_argv = ArgvBuilder.build_argv(backend: nil, prompt: "Nil engine")
    assert "--mode" in nil_argv

    int_argv = ArgvBuilder.build_argv(backend: 123, prompt: "Int engine")
    assert "--mode" in int_argv
  end

  test "ignores whitespace in agy add_dir, log_file, and conversation" do
    opts = [
      backend: :agy,
      prompt: "Terse",
      model: "gemini",
      work_dir: "   ",
      log_file: "   ",
      conversation_id: "   "
    ]

    argv = ArgvBuilder.build_argv(opts)
    refute "--add-dir" in argv
    refute "--log-file" in argv
    refute "--conversation" in argv
  end

  test "executable_path/2 reads the configured backend and honours overrides" do
    assert ArgvBuilder.executable_path(:claude) == ""
    assert ArgvBuilder.executable_path(:agy) == ""

    scope = Rail.Scope.for_system()
    {:ok, _claude} = Rail.Backends.create_backend(scope, %{name: :claude, executable_path: "/configured/claude"})
    {:ok, _agy} = Rail.Backends.create_backend(scope, %{name: :agy, executable_path: "/configured/agy"})

    assert ArgvBuilder.executable_path(:claude) == "/configured/claude"
    assert ArgvBuilder.executable_path(:agy) == "/configured/agy"

    assert ArgvBuilder.executable_path(:claude, claude_path: "/custom/claude") == "/custom/claude"
    assert ArgvBuilder.executable_path(:agy, agy_path: "/custom/agy") == "/custom/agy"
  end
end
