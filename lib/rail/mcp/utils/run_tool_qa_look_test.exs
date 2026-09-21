defmodule Rail.Mcp.Utils.RunToolQaLookTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolQaLook

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  setup do
    stub(Tools, :start_browser_session, fn _task, _opts -> {:ok, :session} end)

    page = %{
      "url" => "http://localhost:4000/bills/new",
      "title" => "New bill",
      "text" => "Vendor\nSave",
      "actions" => [
        %{"node" => 1, "kind" => "click", "label" => "Save", "role" => "button"},
        %{"node" => 2, "kind" => "fill", "label" => "Number", "role" => "textbox", "value" => "QA-1"}
      ]
    }

    %{task: %Task{id: "tsk_qa_look"}, page: page}
  end

  test "reads the page as where it is, what it says and what can be done", %{task: task, page: page} do
    stub(Tools, :observe_browser, fn :session -> {:ok, page} end)

    assert {:ok, text} = run_tool_qa_look(task, %{}, [])
    assert text =~ "http://localhost:4000/bills/new - New bill"
    assert text =~ ~s([1] button "Save")
    assert text =~ ~s([2] textbox "Number" holding "QA-1")
  end

  # A control that is not there and one that was not listed are different
  # answers, and only one of them is worth narrowing the page for.
  test "says what the list left out", %{task: task, page: page} do
    stub(Tools, :observe_browser, fn :session ->
      {:ok, Map.merge(page, %{"omitted_actions" => 12, "omitted_options" => 1842})}
    end)

    assert {:ok, text} = run_tool_qa_look(task, %{}, [])
    assert text =~ "12 more controls not listed"
    assert text =~ "1842 more dropdown options not listed"
  end

  test "says nothing about omissions when the page fitted", %{task: task, page: page} do
    stub(Tools, :observe_browser, fn :session ->
      {:ok, Map.merge(page, %{"omitted_actions" => 0, "omitted_options" => 0})}
    end)

    assert {:ok, text} = run_tool_qa_look(task, %{}, [])
    refute text =~ "not listed"
  end
end
