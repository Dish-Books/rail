defmodule Rail.Tools.Actions.PlainTextTest do
  use ExUnit.Case, async: true

  alias Rail.Tools

  test "drops the colors a command wrote for a terminal" do
    assert Tools.plain_text("\e[1m── tests\e[0m\n  \e[32m✓\e[0m format") == "── tests\n  ✓ format"
  end

  test "keeps what a line redrawn with carriage returns ended as" do
    assert Tools.plain_text("copying 10%\rcopying 55%\rcopying done\r\nnext") == "copying done\nnext"
  end

  test "drops a terminal title or link" do
    assert Tools.plain_text("\e]0;mise run ci\a\e]8;;https://example.com\e\\docs") == "docs"
  end
end
