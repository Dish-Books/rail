defmodule Rail.Mcp.Utils.RunToolBrowserDoTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolBrowserDo

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  setup do
    stub(Tools, :start_browser_session, fn _task, _opts -> {:ok, :session} end)

    %{task: %Task{id: "tsk_browser_do", scratch_path: "/tmp/rail/browser-do"}}
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

    assert {:ok, text} = run_tool_browser_do(task, %{"intent" => "save the bill"}, [])
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

    assert {:ok, text} = run_tool_browser_do(task, %{"intent" => "save the bill"}, [])
    assert text =~ ~s(Stopped: "Save changes" is disabled)
  end

  # Nothing done and nothing left to do is the page saying it was already true,
  # which reads identically to being blocked unless it is said.
  test "a step that did nothing says the page already read as done", %{task: task} do
    receipt = %{outcome: :done, executed: [], url: "http://localhost:4000/bills", title: "Bills"}

    stub(Tools, :drive_browser, fn :session, _intent, _opts -> {:ok, receipt} end)

    assert {:ok, text} = run_tool_browser_do(task, %{"intent" => "click the Sysco option"}, [])
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

    assert {:ok, text} = run_tool_browser_do(task, %{"intent" => "enter and save a bill"}, [])
    assert text =~ ~s(TYPE_TEXT "Number" ← "QA-1")
    assert text =~ ~s(CLICK "Save")
    assert text =~ "Now at http://localhost:4000/bills - Bills"
  end

  # Steps that changed nothing are steps aimed at the wrong thing, and saying
  # that is what stops the caller rewording the same instruction.
  test "steps that left the page as they found it say to name the element another way", %{task: task} do
    receipt = %{
      outcome: :not_moving,
      executed: [%{operation: "CLICK", action: "Confirm vendor"}],
      url: "http://localhost:4000/bills/new",
      title: "New bill"
    }

    stub(Tools, :drive_browser, fn :session, _intent, _opts -> {:ok, receipt} end)

    assert {:ok, text} = run_tool_browser_do(task, %{"intent" => "confirm the vendor"}, [])
    assert text =~ "left the page exactly as they found it"
    assert text =~ "name the element another way"
  end

  # Values are the caller's, whether one field or a form's worth, and they reach
  # the driver as they were given.
  # Every step changed the page, so nothing about any one step looked stuck. The
  # receipt says what it was instead, and that rewording the same thing lands
  # the same way.
  test "steps that went back and forth say the page kept coming back", %{task: task} do
    receipt = %{
      outcome: :going_in_circles,
      executed: [
        %{operation: "SELECT", action: "Select a location → Bori Montrose", text: nil},
        %{operation: "SELECT", action: "Select a location → Bori Memorial", text: nil}
      ],
      url: "http://localhost:4000/bills/new",
      title: "New bill"
    }

    stub(Tools, :drive_browser, fn :session, _intent, _opts -> {:ok, receipt} end)

    assert {:ok, text} = run_tool_browser_do(task, %{"intent" => "the line has a GL account"}, [])
    assert text =~ ~s(SELECT "Select a location → Bori Montrose")
    assert text =~ "kept bringing the page back to where it had already been"
    assert text =~ "say what you want more narrowly"
  end

  test "what to type is handed through as the caller keyed it", %{task: task} do
    values = %{"Number" => "QA-1", "Date" => "2026-08-12"}

    stub(Tools, :drive_browser, fn :session, "a bill is entered", opts ->
      assert Keyword.get(opts, :values) == values
      assert Keyword.get(opts, :text) == nil

      {:ok, %{outcome: :done, executed: [], url: "u", title: "t"}}
    end)

    assert {:ok, _text} = run_tool_browser_do(task, %{"intent" => "a bill is entered", "values" => values}, [])
  end
end
