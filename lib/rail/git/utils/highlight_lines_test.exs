defmodule Rail.Git.Utils.HighlightLinesTest do
  use ExUnit.Case, async: true

  import Rail.Git.Utils.HighlightLines

  test "nothing to highlight is nothing back" do
    assert highlight_lines([], "lib/rail/thing.ex") == []
  end

  test "gives every line its own html, in the order they came" do
    assert [opening, atom, closing] =
             highlight_lines(["defmodule Thing do", "  :ok", "end"], "lib/rail/thing.ex")

    assert opening =~ ~s(class="l-keyword")
    assert opening =~ "Thing"
    assert atom =~ ":ok"
    assert closing =~ "end"
  end

  test "escapes the code it highlights" do
    assert [html] = highlight_lines([~s(  @doc "<script>")], "lib/rail/thing.ex")

    refute html =~ "<script>"
    assert html =~ "&lt;"
  end

  # A heredoc is the case a line at a time gets wrong, so the whole block goes
  # through together.
  test "reads the lines as one piece of code" do
    fence = ~s(    body = \"\"\")
    lines = [fence, "    # not a comment", fence]

    assert [_open, inside, _close] = highlight_lines(lines, "lib/rail/thing.ex")

    assert inside =~ "l-string"
    refute inside =~ "l-comment"
  end

  # A diff shows whatever is in the file, and not every file is text.
  test "leaves a line no highlighter can read to the caller" do
    assert highlight_lines([<<0xFF, 0xFE>>, "def x, do: 1"], "lib/rail/thing.ex") == [nil, nil]
  end

  test "leaves a language it cannot highlight to the caller" do
    assert highlight_lines(["some prose", "and more"], "notes/README") == [nil, nil]
  end

  # Every parser but Elixir's is fetched on first use, which a test run must not
  # do; `config :rail, :fetch_parsers, false` is what keeps the suite offline.
  test "leaves a language it would have to fetch a parser for to the caller" do
    assert highlight_lines(["const a = 1;"], "assets/js/app.js") == [nil]
  end
end
