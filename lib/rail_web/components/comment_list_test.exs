defmodule RailWeb.Components.CommentListTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingComment
  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Pipeline.Schemas.ScreenComment
  alias Rail.Roles.Schemas.Role
  alias Rail.Users.Schemas.User
  alias RailWeb.Components.CommentList

  setup do
    at = ~U[2026-10-27 14:20:00Z]
    ada = %User{id: "usr_ada", name: "Ada", login: "ada"}
    tom = %User{id: "usr_tom", name: nil, login: "tom"}
    plan = %PlanComment{target: :plan, element_label: "File 3 · lib/send.ex", element_text: "", status: :sent}

    entries = [
      %{
        kind: :message,
        id: "rev_message",
        at: at,
        user: tom,
        comment: %{body: "Check the tray.", role: %Role{name: "Review lead", stage: :review_lead}, run_id: "run_1"}
      },
      %{
        kind: :diff,
        id: "dcm_1",
        at: at,
        user: ada,
        comment: %DiffComment{id: "dcm_1", path: "lib/tray.ex", line: 88, body: "Use the button.", status: :resolved}
      },
      %{
        kind: :screen,
        id: "scm_1",
        at: at,
        user: ada,
        comment: %ScreenComment{id: "scm_1", key: "tray", label: "Tray", body: "Fold it.", status: :unsent}
      },
      %{
        kind: :screen,
        id: "scm_2",
        at: at,
        user: tom,
        comment: %ScreenComment{id: "scm_2", key: "empty", label: "Empty tray", body: "Hide Send.", status: :sent}
      },
      %{
        kind: :finding,
        id: "fcm_1",
        at: at,
        user: tom,
        comment: %FindingComment{
          id: "fcm_1",
          label: "Fix",
          body: "Don't fix.",
          status: :sent,
          finding: %Finding{key: "send-twice"}
        }
      },
      %{
        kind: :plan,
        id: "pcm_ticket",
        at: at,
        user: tom,
        comment: %{plan | target: :ticket, element_label: "Item 4", body: "Add the negative case."}
      },
      %{kind: :plan, id: "pcm_plan", at: at, user: tom, comment: %{plan | body: "Once a turn?"}},
      %{
        kind: :plan,
        id: "pcm_fix",
        at: at,
        user: tom,
        comment: %{plan | target: :fix_plan, element_label: "Decision 2", body: "Batch them.", status: :queued}
      },
      %{
        kind: :plan,
        id: "pcm_design",
        at: at,
        user: tom,
        comment: %PlanComment{
          target: :design,
          option_key: "one-list",
          element_text: "Send 3",
          element_tag: "button",
          body: "Say what it sends.",
          status: :sent
        }
      },
      %{
        kind: :plan,
        id: "pcm_blank",
        at: at,
        user: tom,
        comment: %PlanComment{
          target: :design,
          option_key: "one-list",
          element_text: "",
          element_tag: "img",
          body: "Bigger.",
          status: :sent
        }
      },
      %{
        kind: :message,
        id: "rev_gone",
        at: at,
        user: nil,
        comment: %{body: "Hi.", role: %Role{name: "Plan"}, run_id: "r"}
      }
    ]

    %{entries: entries}
  end

  test "each kind of row names where it opens, leading its accessible name, and a gone screen reads Open Screens", %{
    entries: entries
  } do
    html =
      render_component(&CommentList.comment_list/1,
        comments: entries,
        order: "newest",
        screen_keys: ["tray"],
        reader_id: "usr_ada",
        target: nil
      )

    doc = Floki.parse_fragment!(html)

    opens = fn id -> doc |> Floki.find("#comment-#{id} [data-qa=comment_opens]") |> Floki.text() |> String.trim() end
    named = fn id -> doc |> Floki.find("#comment-#{id} .sr-only") |> Floki.text() |> String.trim() end

    assert opens.("rev_message") == "Open the conversation"
    assert opens.("dcm_1") == "Open in Diff"
    assert opens.("scm_1") == "Open the screen"
    assert opens.("scm_2") == "Open Screens"
    assert opens.("fcm_1") == "Open the finding"
    assert opens.("pcm_ticket") == "Open in Plan"
    assert named.("scm_2") == "Open Screens:"
    assert named.("dcm_1") == "Open in Diff:"

    assert Floki.text(Floki.find(doc, "#comment-scm_2 [data-qa=comment_shot_gone]")) =~ "No shot of this screen now"
    assert Floki.find(doc, "#comment-scm_1 [data-qa=comment_shot_gone]") == []
  end

  test "each row says who, what it was on and its words, and marks the reader's unsent and a resolved one", %{
    entries: entries
  } do
    html =
      render_component(&CommentList.comment_list/1,
        comments: entries,
        order: "newest",
        screen_keys: ["tray"],
        reader_id: "usr_ada",
        target: nil
      )

    doc = Floki.parse_fragment!(html)
    text = fn id -> doc |> Floki.find("#comment-#{id}") |> Floki.text() |> String.split() |> Enum.join(" ") end

    assert Floki.text(Floki.find(doc, "[data-qa=comments_count]")) =~ "11"
    assert text.("rev_message") =~ "tom"
    assert text.("rev_message") =~ "Review lead conversation"
    assert text.("rev_gone") =~ "Someone"
    assert text.("dcm_1") =~ "You"
    assert text.("dcm_1") =~ "Diff lib/tray.ex:88"
    assert text.("dcm_1") =~ "Resolved"
    assert text.("scm_1") =~ "Not sent"
    assert text.("scm_1") =~ "Screen Tray"
    assert text.("fcm_1") =~ "Finding send-twice · Fix"
    assert text.("pcm_ticket") =~ "Ticket Item 4"
    assert text.("pcm_plan") =~ "Plan File 3 · lib/send.ex"
    assert text.("pcm_fix") =~ "Next round's plan Decision 2"
    assert text.("pcm_design") =~ ~s(Design one-list · "Send 3")
    assert text.("pcm_blank") =~ "Design one-list · <img>"
    refute text.("pcm_fix") =~ "Not sent"
    refute text.("scm_2") =~ "Not sent"

    assert Floki.attribute(doc, "#comment-order-newest", "aria-pressed") == ["true"]
  end

  test "a comment on a custom stage's file names the stage and its line and opens in it, or in its stage with none", %{
    entries: [%{at: at} | _rest]
  } do
    output = %PlanComment{target: :output, element_label: "Paragraph 2", body: "Say saxy.", status: :sent}

    html =
      render_component(&CommentList.comment_list/1,
        comments: [
          %{
            kind: :plan,
            id: "pcm_license",
            at: at,
            user: nil,
            comment: %{output | custom_stage: "License check"}
          },
          %{kind: :plan, id: "pcm_older", at: at, user: nil, comment: output}
        ],
        order: "newest",
        screen_keys: [],
        reader_id: "usr_ada",
        target: nil
      )

    doc = Floki.parse_fragment!(html)
    text = fn id -> doc |> Floki.find("#comment-#{id}") |> Floki.text() |> String.split() |> Enum.join(" ") end
    opens = fn id -> doc |> Floki.find("#comment-#{id} [data-qa=comment_opens]") |> Floki.text() |> String.trim() end

    assert text.("pcm_license") =~ "License check Paragraph 2"
    assert opens.("pcm_license") == "Open in License check"
    assert text.("pcm_older") =~ "Output Paragraph 2"
    assert opens.("pcm_older") == "Open its stage"
  end

  test "with no comments it says there are none yet" do
    html =
      render_component(&CommentList.comment_list/1,
        comments: [],
        order: "oldest",
        screen_keys: [],
        reader_id: "usr_ada",
        target: nil
      )

    assert html =~ "No comments yet"
    assert html =~ "Messages to an agent and comments on the plan, diff, screens and findings appear here."
    refute html =~ "comment-list"
  end
end
