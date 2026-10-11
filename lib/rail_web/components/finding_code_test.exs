defmodule RailWeb.Components.FindingCodeTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.FindingCode

  @row %{kind: :line, line_kind: :context, old_line: nil, new_line: 40, text: "line 40", named?: true}
  @excerpt %{rows: [@row], changed?: false, hidden_lines: 0, other_changes: 0}
  @head "9e4f1c2aaaabbbbcccc"

  test "unchanged lines say so and name the commit they read as, and changed ones do not" do
    unchanged =
      (&FindingCode.finding_code/1) |> render_component(excerpt: @excerpt, head: @head) |> Floki.parse_fragment!()

    assert "The branch does not change these lines. They read as the file does on 9e4f1c2." =
             unchanged
             |> Floki.find("[data-qa=finding_code_unchanged]")
             |> Floki.text()
             |> String.split()
             |> Enum.join(" ")

    assert [_bracketed] = Floki.find(unchanged, "[data-bracket=only]")

    changed =
      (&FindingCode.finding_code/1)
      |> render_component(excerpt: %{@excerpt | changed?: true}, head: @head)
      |> Floki.parse_fragment!()

    assert [] = Floki.find(changed, "[data-qa=finding_code_unchanged]")
  end

  test "the footer counts what the excerpt leaves out of the file, and is absent when nothing is" do
    cases = [
      {%{changed?: true, hidden_lines: 1, other_changes: 2}, "1 more changed line and 2 other changes in this file."},
      {%{changed?: true, hidden_lines: 12, other_changes: 0}, "12 more changed lines in this file."},
      {%{changed?: true, hidden_lines: 0, other_changes: 1}, "1 other change in this file."},
      {%{changed?: false, hidden_lines: 0, other_changes: 1}, "1 change elsewhere in this file, none on these lines."},
      {%{changed?: false, hidden_lines: 0, other_changes: 2}, "2 changes elsewhere in this file, none on these lines."}
    ]

    for {counts, footer} <- cases do
      html = render_component(&FindingCode.finding_code/1, excerpt: Map.merge(@excerpt, counts))

      assert ^footer =
               html
               |> Floki.parse_fragment!()
               |> Floki.find("[data-qa=finding_code_footer]")
               |> Floki.text()
               |> String.split()
               |> Enum.join(" ")
    end

    for counts <- [%{changed?: true}, %{changed?: false}] do
      html = render_component(&FindingCode.finding_code/1, excerpt: Map.merge(@excerpt, counts))
      refute html =~ "finding_code_footer"
    end
  end

  # The wrap variant reads `data-diff-wrap` on an ancestor, so the excerpt wraps whatever the Diff item does.
  test "the excerpt always wraps" do
    html = (&FindingCode.finding_code/1) |> render_component(excerpt: @excerpt) |> Floki.parse_fragment!()

    assert [_wrapped] = Floki.find(html, "[data-qa=finding_code][data-diff-wrap] [data-qa=diff_hunk]")

    assert html |> Floki.find("[data-qa=finding_code_unchanged]") |> Floki.text() |> String.split() |> Enum.join(" ") =~
             "the file does."
  end
end
