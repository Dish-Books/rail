defmodule RailWeb.Components.DiffCommentListTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Users.Schemas.User
  alias RailWeb.Components.DiffCommentList

  setup do
    comment = %DiffComment{
      id: "dcm_unsent",
      path: "lib/rail_web/live/engineer_stage.ex",
      line_kind: :added,
      line: 94,
      line_text: ":if={@show_run_ci?}",
      filter: :branch,
      body: "Hide this while review is running too.",
      status: :unsent
    }

    sent = %{comment | id: "dcm_sent", line: 118, body: "This disables Run CI for the wrong reason.", status: :sent}

    resolved = %{
      comment
      | id: "dcm_resolved",
        line_kind: :deleted,
        line: 96,
        body: "Keep the failed label.",
        status: :resolved
    }

    %{
      groups: [
        %{status: :unsent, label: "Not sent", rows: [%{comment: comment, changed?: false, mine?: true}]},
        %{status: :sent, label: "Sent", rows: [%{comment: sent, changed?: true, mine?: true}]},
        %{status: :resolved, label: "Resolved", rows: [%{comment: resolved, changed?: false, mine?: true}]}
      ]
    }
  end

  test "lists each comment under its state with how many there are", %{groups: groups} do
    html = render_component(&DiffCommentList.diff_comment_list/1, groups: groups, target: nil)

    assert html |> Floki.parse_fragment!() |> Floki.text() =~
             ~r/Not sent\s*1.*Line 94.*engineer_stage\.ex.*Hide this.*Sent\s*1.*Line 118.*changed.*Resolved\s*1.*Removed line 96.*Keep the failed label\./s

    refute html =~ "lib/rail_web/live/"
  end

  test "a state with no comments is left out", %{groups: [unsent | _rest]} do
    html = render_component(&DiffCommentList.diff_comment_list/1, groups: [unsent], target: nil)

    refute html =~ "diff_comment_group_sent"
    refute html =~ "diff_comment_group_resolved"
  end

  test "says so when there are none" do
    assert render_component(&DiffCommentList.diff_comment_list/1, groups: [], target: nil) =~
             "Nobody has commented on this diff yet."
  end

  test "only a sent or resolved comment can be resolved from here, ticked when it is", %{groups: groups} do
    html = render_component(&DiffCommentList.diff_comment_list/1, groups: groups, target: nil)

    assert [sent, resolved] = html |> Floki.parse_fragment!() |> Floki.find("[data-qa='diff_comment_list_resolve']")
    assert Floki.attribute(sent, "phx-value-id") == ["dcm_sent"]
    assert Floki.attribute(sent, "aria-checked") == ["false"]
    assert Floki.attribute(sent, "phx-value-resolved") == ["true"]
    assert Floki.attribute(resolved, "aria-checked") == ["true"]
    assert Floki.attribute(resolved, "phx-value-resolved") == ["false"]
  end

  test "only a comment whose line changed is marked so", %{groups: groups} do
    html = render_component(&DiffCommentList.diff_comment_list/1, groups: groups, target: nil)

    assert [marked] = html |> Floki.parse_fragment!() |> Floki.find("[data-qa='diff_comment_list_changed']")
    assert Floki.attribute(marked, "title") == ["Line changed"]
  end

  test "each row jumps to its comment, and the one jumped to is marked", %{groups: groups} do
    html = render_component(&DiffCommentList.diff_comment_list/1, groups: groups, selected: "dcm_sent", target: nil)
    document = Floki.parse_fragment!(html)

    assert ["dcm_unsent", "dcm_sent", "dcm_resolved"] =
             document |> Floki.find("[data-qa='diff_comment_list_jump']") |> Floki.attribute("phx-value-id")

    assert ["false", "true", "false"] =
             document |> Floki.find("[data-qa='diff_comment_list_row']") |> Floki.attribute("aria-current")
  end

  test "someone else's comment names them and has no box to resolve it", %{groups: groups} do
    [_unsent, %{rows: [%{comment: sent}]} = sent_group, %{rows: [%{comment: resolved}]} = resolved_group] = groups
    grace = %User{login: "grace", name: "Grace Hopper"}

    theirs = [
      %{sent_group | rows: [%{comment: %{sent | user: grace}, changed?: false, mine?: false}]},
      %{resolved_group | rows: [%{comment: %{resolved | user: grace}, changed?: false, mine?: false}]}
    ]

    html = render_component(&DiffCommentList.diff_comment_list/1, groups: theirs, target: nil)
    document = Floki.parse_fragment!(html)

    assert [] = Floki.find(document, "[data-qa='diff_comment_list_resolve']")
    assert [_sent, _resolved] = Floki.find(document, "[data-qa='diff_comment_list_mark']")

    assert ["Grace Hopper", "Grace Hopper"] =
             document |> Floki.find("[data-qa='diff_comment_list_author']") |> Enum.map(&String.trim(Floki.text(&1)))
  end

  # The name is the part a reader looks for, so it is not squeezed into the
  # line label, changed mark and file name.
  test "someone else's name has a line of its own, apart from the line and file", %{groups: groups} do
    [_unsent, %{rows: [%{comment: sent}]} = sent_group | _resolved] = groups
    dana = %User{login: "dana", name: "Dana Reyes"}
    theirs = [%{sent_group | rows: [%{comment: %{sent | user: dana}, changed?: true, mine?: false}]}]

    html = render_component(&DiffCommentList.diff_comment_list/1, groups: theirs, target: nil)
    document = Floki.parse_fragment!(html)

    assert [author] = Floki.find(document, "[data-qa='diff_comment_list_author']")
    assert String.trim(Floki.text(author)) == "Dana Reyes"
    refute hd(Floki.attribute(author, "class")) =~ "max-w"
    assert [] = Floki.find(document, "[data-qa='diff_comment_list_meta'] [data-qa='diff_comment_list_author']")
    assert [_meta] = Floki.find(document, "[data-qa='diff_comment_list_meta']")
  end
end
