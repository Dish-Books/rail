defmodule Rail.Mcp.Utils.RunToolQaDoTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolQaDo

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  setup do
    stub(Tools, :start_browser_session, fn _task, _opts -> {:ok, :session} end)

    %{task: %Task{id: "tsk_qa_do", scratch_path: "/tmp/rail/qa-do"}}
  end

  # The page said no and said why, twice over a page that had not moved. That is
  # an answer about the application, and the wording is what stops the caller
  # asking the same thing in different words.
  test "a refusal says what refused it and what was in the way", %{task: task} do
    receipt = %{
      outcome: {:refused, %{label: "Save changes", why: "covered", by: ~s(div "Saving")}},
      executed: [],
      url: "http://localhost:4000/bills/new",
      title: "New bill"
    }

    stub(Tools, :drive_browser, fn :session, _intent, _opts -> {:ok, receipt} end)

    assert {:ok, text} = run_tool_qa_do(task, %{"intent" => "save the bill"}, [])
    assert text =~ ~s(Stopped: "Save changes" is covered by div "Saving")
    assert text =~ "the page's answer rather than something to word differently"
  end

  test "a refusal with nothing in the way names only the reason", %{task: task} do
    receipt = %{
      outcome: {:refused, %{label: "Save changes", why: "disabled", by: nil}},
      executed: [],
      url: "http://localhost:4000/bills/new",
      title: "New bill"
    }

    stub(Tools, :drive_browser, fn :session, _intent, _opts -> {:ok, receipt} end)

    assert {:ok, text} = run_tool_qa_do(task, %{"intent" => "save the bill"}, [])
    assert text =~ ~s(Stopped: "Save changes" is disabled)
  end

  # Nothing done and nothing left to do is the page saying it was already true,
  # which reads identically to being blocked unless it is said.
  test "a step that did nothing says the page already read as done", %{task: task} do
    receipt = %{outcome: :done, executed: [], url: "http://localhost:4000/bills", title: "Bills"}

    stub(Tools, :drive_browser, fn :session, _intent, _opts -> {:ok, receipt} end)

    assert {:ok, text} = run_tool_qa_do(task, %{"intent" => "click the Sysco option"}, [])
    assert text =~ "Did nothing: the page already reads as having that carried out"
    assert text =~ "the same instruction reworded lands the same way"
  end

  test "the steps it did take are what it reports", %{task: task} do
    receipt = %{
      outcome: :done,
      executed: [%{operation: "TYPE_TEXT", action: "Number", text: "QA-1"}, %{operation: "CLICK", action: "Save"}],
      url: "http://localhost:4000/bills",
      title: "Bills"
    }

    stub(Tools, :drive_browser, fn :session, _intent, _opts -> {:ok, receipt} end)

    assert {:ok, text} = run_tool_qa_do(task, %{"intent" => "enter and save a bill"}, [])
    assert text =~ ~s(TYPE_TEXT "Number" ← "QA-1")
    assert text =~ ~s(CLICK "Save")
    assert text =~ "Now at http://localhost:4000/bills - Bills"
  end

  # Values are the caller's, whether one field or a form's worth, and they reach
  # the driver as they were given.
  test "what to type is handed through as the caller keyed it", %{task: task} do
    values = %{"Number" => "QA-1", "Date" => "2026-08-12"}

    stub(Tools, :drive_browser, fn :session, "a bill is entered", opts ->
      assert Keyword.get(opts, :values) == values
      assert Keyword.get(opts, :text) == nil

      {:ok, %{outcome: :done, executed: [], url: "u", title: "t"}}
    end)

    assert {:ok, _text} = run_tool_qa_do(task, %{"intent" => "a bill is entered", "values" => values}, [])
  end
end
