defmodule Rail.Runs.ToolSummarizerTest do
  use Rail.DataCase, async: true

  alias Rail.Runs.ToolSummarizer

  test "summarizes prioritized keys in order with 1-arity" do
    assert ToolSummarizer.summarize_tool_input(%{"file_path" => "/lib/app.ex"}) == "/lib/app.ex"
    assert ToolSummarizer.summarize_tool_input(%{"path" => "/lib/test.ex"}) == "/lib/test.ex"
    assert ToolSummarizer.summarize_tool_input(%{"command" => "mix test"}) == "mix test"
    assert ToolSummarizer.summarize_tool_input(%{"pattern" => "defmodule"}) == "defmodule"
    assert ToolSummarizer.summarize_tool_input(%{"query" => "find me"}) == "find me"
    assert ToolSummarizer.summarize_tool_input(%{"url" => "https://example.com"}) == "https://example.com"
  end

  test "summarizes Agy capitalized keys" do
    assert ToolSummarizer.summarize_tool_input(%{"AbsolutePath" => "/repo/file.dart"}) == "/repo/file.dart"
    assert ToolSummarizer.summarize_tool_input(%{"TargetFile" => "/repo/target.ex"}) == "/repo/target.ex"
    assert ToolSummarizer.summarize_tool_input(%{"CommandLine" => "git status"}) == "git status"
    assert ToolSummarizer.summarize_tool_input(%{"Pattern" => "*.ex"}) == "*.ex"
    assert ToolSummarizer.summarize_tool_input(%{"Query" => "search text"}) == "search text"
    assert ToolSummarizer.summarize_tool_input(%{"SearchDirectory" => "/tmp/dir"}) == "/tmp/dir"
    assert ToolSummarizer.summarize_tool_input(%{"DirectoryPath" => "/var/log"}) == "/var/log"
  end

  test "supports atom keys" do
    assert ToolSummarizer.summarize_tool_input(%{file_path: "/lib/atom.ex"}) == "/lib/atom.ex"
    assert ToolSummarizer.summarize_tool_input(%{command: "echo 1"}) == "echo 1"
    assert ToolSummarizer.summarize_tool_input(%{TargetFile: "/repo/target.ex"}) == "/repo/target.ex"
  end

  test "skips nil prioritized values in string and atom maps" do
    assert ToolSummarizer.summarize_tool_input(%{"file_path" => nil, "command" => "mix test"}) ==
             "mix test"

    assert ToolSummarizer.summarize_tool_input(%{file_path: nil, command: "mix test"}) ==
             "mix test"
  end

  test "summarizes with 2-arity tool_name and params" do
    assert ToolSummarizer.summarize_tool_input("view_file", %{"AbsolutePath" => "/repo/main.dart"}) ==
             "/repo/main.dart"

    assert ToolSummarizer.summarize_tool_input(:run_command, %{"command" => "mix compile"}) ==
             "mix compile"
  end

  test "falls back to keys list when no prioritized key matches" do
    params = %{"foo" => 1, "bar" => 2}
    result = ToolSummarizer.summarize_tool_input(params)
    assert result == "bar, foo" or result == "foo, bar"
  end

  test "handles string params" do
    assert ToolSummarizer.summarize_tool_input("echo hello") == "echo hello"
  end

  test "handles nil and non-map inputs" do
    assert ToolSummarizer.summarize_tool_input(nil) == ""
    assert ToolSummarizer.summarize_tool_input(123) == ""
    assert ToolSummarizer.summarize_tool_input([]) == ""
  end

  test "truncates long values to 160 chars and appends ellipsis" do
    long_string = String.duplicate("a", 200)
    summarized = ToolSummarizer.summarize_tool_input(%{"command" => long_string})
    assert String.length(summarized) == 161
    assert String.ends_with?(summarized, "…")
    assert String.slice(summarized, 0, 160) == String.duplicate("a", 160)
  end

  test "truncates long fallback key list to 80 chars" do
    params =
      for i <- 1..20, into: %{} do
        {"key_number_#{i}_very_long_name", i}
      end

    summarized = ToolSummarizer.summarize_tool_input(params)
    assert String.length(summarized) <= 81
    assert String.ends_with?(summarized, "…")
  end

  test "truncate/2 flattens newlines and trims" do
    assert ToolSummarizer.truncate("  hello\nworld\n  ", 20) == "hello world"
    assert ToolSummarizer.truncate(nil, 10) == ""
    assert ToolSummarizer.truncate(42, 10) == "42"
    assert ToolSummarizer.truncate("exact10ch!", 10) == "exact10ch!"
    assert ToolSummarizer.truncate("elevenchar!", 10) == "elevenchar…"
    assert ToolSummarizer.truncate("12345678901", 10) == "1234567890…"
  end
end
