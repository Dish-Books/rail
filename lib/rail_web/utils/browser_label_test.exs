defmodule RailWeb.Utils.BrowserLabelTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.BrowserLabel

  test "a numbered explorer browser is that QA explorer, and the demo browser is the Demo recorder" do
    assert browser_label("explorer-2") == "QA explorer 2"
    assert browser_label("demo") == "Demo recorder"
  end

  test "any other browser keeps the name it was given" do
    assert browser_label("explorer-x") == "explorer-x"
    assert browser_label("qa") == "qa"
  end
end
