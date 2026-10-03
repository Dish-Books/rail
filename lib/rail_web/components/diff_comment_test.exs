defmodule RailWeb.Components.DiffCommentTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Users.Schemas.User
  alias RailWeb.Components.DiffComment, as: Card

  test "under its line it is the comment alone, not yet sent" do
    comment = %{
      %DiffComment{
        path: "lib/rail/feature.ex",
        line_kind: :added,
        line: 1,
        line_text: "def feature, do: :ok",
        filter: :branch,
        body: "Name this for what it does."
      }
      | id: "dcm_placed",
        body: "Name this for what it does."
    }

    html = render_component(&Card.diff_comment/1, comment: comment, mine?: true)

    assert html =~ "Not sent"
    assert html =~ "Name this for what it does."
    assert html =~ ~s(id="diff-comment-dcm_placed")
    assert html =~ "diff_comment_remove"
    refute html =~ "diff_comment_resolve"
    refute html =~ "diff_comment_quote"
  end

  test "a sent comment can be resolved, and no longer removed" do
    comment = %DiffComment{
      id: "dcm_sent",
      path: "lib/rail/feature.ex",
      line_kind: :added,
      line: 1,
      line_text: "def feature, do: :ok",
      filter: :branch,
      body: "Name this for what it does.",
      status: :sent
    }

    html = render_component(&Card.diff_comment/1, comment: comment, mine?: true)

    assert html =~ "Sent"
    assert html =~ "Name this for what it does."
    assert html =~ ~s(phx-click="resolve_diff_comment")
    assert html =~ ~s(phx-value-resolved="true")
    refute html =~ "Not sent"
    refute html =~ "diff_comment_remove"
  end

  test "a resolved comment is one line until it is opened" do
    comment = %DiffComment{
      id: "dcm_resolved",
      path: "lib/rail/feature.ex",
      line_kind: :deleted,
      line: 96,
      line_text: ~s[defp ci_label(%{state: :failed}), do: "CI failed"],
      filter: :branch,
      body: "Keep the failed label.",
      status: :resolved
    }

    folded = render_component(&Card.diff_comment/1, comment: comment, mine?: true, lifted?: true, changed?: true)

    assert [row] = folded |> Floki.parse_fragment!() |> Floki.find("button[data-qa='diff_comment']")
    assert Floki.attribute(row, "aria-expanded") == ["false"]
    assert Floki.attribute(row, "phx-click") == ["toggle_diff_comment"]
    assert Floki.text(row) =~ ~r/Resolved.*Keep the failed label\..*Line changed/s
    refute folded =~ "diff_comment_quote"
    refute folded =~ "Unresolve"

    open =
      render_component(&Card.diff_comment/1,
        comment: comment,
        mine?: true,
        lifted?: true,
        changed?: true,
        open?: true
      )

    assert open =~
             ~r/Resolved.*Line changed.*Unresolve.*Removed line 96 when you commented.*CI failed.*Keep the failed label\./s

    assert open =~ ~s(phx-value-resolved="false")
    assert open =~ ~s(aria-label="Fold comment")
    refute open =~ "diff_comment_remove"
  end

  test "lifted off an unchanged line, it quotes the line as it read" do
    comment = %{
      %DiffComment{
        path: "lib/rail/feature.ex",
        line_kind: :added,
        line: 1,
        line_text: "def feature, do: :ok",
        filter: :branch,
        body: "Name this for what it does."
      }
      | id: "dcm_lifted",
        line_kind: :context,
        line: 39,
        line_text: "  filters = parse()"
    }

    html = render_component(&Card.diff_comment/1, comment: comment, mine?: true, lifted?: true)

    assert html =~ "Line 39 when you commented"
    assert [quote] = html |> Floki.parse_fragment!() |> Floki.find("[data-qa='diff_comment_quote']")
    assert Floki.text(quote) =~ "  filters = parse()"
  end

  # Everyone sees a sent comment, but only its author acts on it.
  test "someone else's comment names them and offers nothing to do but open it" do
    comment = %DiffComment{
      id: "dcm_teammates",
      path: "lib/rail/feature.ex",
      line_kind: :added,
      line: 7,
      line_text: "def feature, do: :ok",
      filter: :branch,
      body: "Name this for what it does.",
      status: :sent,
      user: %User{login: "grace", name: nil}
    }

    sent = render_component(&Card.diff_comment/1, comment: comment, mine?: false, lifted?: true)

    assert sent =~ ~r/grace.*Sent.*Line 7 when grace commented/s
    refute sent =~ "You"
    refute sent =~ "diff_comment_resolve"
    refute sent =~ "diff_comment_remove"

    named = %{comment | status: :resolved, user: %User{login: "grace", name: "Grace Hopper"}}
    open = render_component(&Card.diff_comment/1, comment: named, mine?: false, open?: true)

    assert open =~ "Grace Hopper"
    assert open =~ "diff_comment_fold"
    refute open =~ "Unresolve"
  end
end
