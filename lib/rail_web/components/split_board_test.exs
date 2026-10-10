defmodule RailWeb.Components.SplitBoardTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import RailWeb.Utils.ChildStatus

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles.Schemas.Role
  alias RailWeb.Components.SplitBoard

  setup do
    now = DateTime.utc_now()
    roles = Map.new([:engineer, :review_lead], &{&1, %Role{id: "rol_#{&1}", name: "#{&1} role", stage: &1}})
    run = &struct(%Run{role: roles[&1], role_id: roles[&1].id, questions: [], started_at: now}, &2)
    error = "mix test exited with 2: ** (CompileError) lib/rail_web/components/review_items.ex:214: undefined"

    children =
      Enum.map(
        [
          {1, issue: %{completed_at: now}, pr_number: 171},
          {2, stage: :review, runs: [run.(:review_lead, status: :finished, stage_outcome: :done)]},
          {3, runs: [run.(:engineer, status: :blocked_on_input, questions: [%Question{status: :pending}])]},
          {4, runs: [run.(:engineer, status: :failed, error: error)]},
          {5, builds_on: [3, 4]},
          {6, issue: %{state: :canceled}},
          {7, runs: [run.(:engineer, status: :waiting_for_resources)]},
          {8, builds_on: [6]}
        ],
        fn {position, attrs} ->
          {issue, attrs} = Keyword.pop(attrs, :issue, %{})

          struct(
            %Task{
              id: "tsk_#{position}",
              split_position: position,
              builds_on: [],
              stage: :engineer,
              runs: [],
              scratch_path: "/nonexistent/split_board",
              issue: struct(%Issue{identifier: "SPL-#{position}", title: "Child #{position}"}, issue)
            },
            attrs
          )
        end
      )

    board =
      (&SplitBoard.split_board/1)
      |> render_component(statuses: Enum.map(children, &child_status(&1, children)), parent_id: "tsk_parent")
      |> Floki.parse_fragment!()

    %{board: board, children: children, error: error}
  end

  test "the header reads each column once, with no QA or Demo", %{board: board} do
    assert ["#", "Child", "Engineer", "Review", "Merged", "Where it stands"] =
             board |> Floki.find("thead th") |> Enum.map(&String.trim(Floki.text(&1)))
  end

  test "every row has a cell under each header and each declared column, in every state", %{board: board} do
    columns = length(Floki.find(board, "colgroup col"))

    assert ^columns = length(Floki.find(board, "thead th"))
    assert 8 = length(Floki.find(board, "tbody tr"))

    for row <- Floki.find(board, "tbody tr") do
      assert {_id, ^columns} = {Floki.attribute(row, "id"), length(Floki.find(row, "td"))}
    end
  end

  test "a merged or waiting row says so under Where it stands with no link, and Merged holds only its chip", %{
    board: board
  } do
    assert "Merged · PR #171" = Floki.text(Floki.find(board, "#split-row-SPL-1 td:last-child [data-qa=split-row-line]"))
    assert [] = Floki.find(board, "#split-row-SPL-1 td:last-child a")
    assert "Merged" = board |> Floki.find("#split-row-SPL-1 td:nth-child(5)") |> Floki.text() |> String.trim()

    assert "Starts when SPL-3 and SPL-4 merge" =
             Floki.text(Floki.find(board, "#split-row-SPL-5 td:last-child [data-qa=split-row-line]"))

    assert [] = Floki.find(board, "#split-row-SPL-5 td:last-child a")
    assert [] = Floki.find(board, "#split-row-SPL-5 td:nth-child(5) [title]")
  end

  test "a failed row clamps its error to two lines, carries it whole on hover and puts Fix under it", %{
    board: board,
    error: error
  } do
    [line] = Floki.find(board, "#split-row-SPL-4 td:last-child [data-qa=split-row-line]")
    full = "Engineer failed: #{error}"

    assert [^full] = Floki.attribute(line, "title")
    assert [class] = Floki.attribute(line, "class")
    assert class =~ "line-clamp-2"
    refute class =~ "truncate"

    assert "Fix" =
             board |> Floki.find("#split-row-SPL-4 td:last-child #split-action-SPL-4") |> Floki.text() |> String.trim()
  end

  test "findings to rule and a question read in full with their whole link under them in the last column", %{
    board: board
  } do
    for {row, line, action} <- [
          {"SPL-2", "Findings to rule", "Review the findings"},
          {"SPL-3", "engineer role asked a question", "Answer"}
        ] do
      assert ^line = Floki.text(Floki.find(board, "#split-row-#{row} td:last-child [data-qa=split-row-line]"))

      assert [link] = Floki.find(board, "#split-row-#{row} td:last-child #split-action-#{row}")
      assert ^action = link |> Floki.text() |> String.trim()
      assert [class] = Floki.attribute(link, "class")
      assert class =~ "whitespace-nowrap"
    end
  end

  test "a line keeps each sibling identifier it names in one unbroken piece", %{board: board} do
    assert ["SPL-3", "SPL-4"] =
             board
             |> Floki.find("#split-row-SPL-5 [data-qa=split-row-line] .whitespace-nowrap")
             |> Enum.map(&Floki.text/1)

    assert ["SPL-6"] =
             board
             |> Floki.find("#split-row-SPL-8 [data-qa=split-row-line] .whitespace-nowrap")
             |> Enum.map(&Floki.text/1)

    assert "SPL-6 was canceled, so this will not start; cancel it in Linear to finish the split" =
             Floki.text(Floki.find(board, "#split-row-SPL-8 [data-qa=split-row-line]"))
  end

  test "a child's title clamps at two lines, with nothing undoing the clamp, and shows whole on hover", %{
    board: board
  } do
    [title] = Floki.find(board, "#split-open-SPL-1 [data-qa=split-row-title]")

    assert ["Child 1"] = Floki.attribute(title, "title")
    assert [class] = Floki.attribute(title, "class")
    assert "line-clamp-2" in String.split(class)
    refute "block" in String.split(class)
  end

  test "a chip wider than its column truncates its label inside it and names it whole on hover", %{board: board} do
    assert [chip] = Floki.find(board, "#split-row-SPL-7 td:nth-child(3) [title='Waiting for resources']")
    assert ["truncate"] = chip |> Floki.find("span.truncate") |> Floki.attribute("class")
    assert "Waiting for resources" = chip |> Floki.text() |> String.trim()
  end

  test "a done stage reads Done to a screen reader", %{board: board} do
    assert ["Done", "Done"] = board |> Floki.find("#split-row-SPL-1 .sr-only") |> Enum.map(&Floki.text/1)
  end
end
