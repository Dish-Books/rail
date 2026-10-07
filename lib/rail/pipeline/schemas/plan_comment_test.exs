defmodule Rail.Pipeline.Schemas.PlanCommentTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Pipeline.Schemas.PlanCommentCapture

  setup do
    attrs = %{
      "target" => "design",
      "body" => "  Say how long the oldest one has waited.  ",
      "option_key" => "waiting-lanes",
      "selector" => "#lane-needs-you > header:nth-child(1) > h2:nth-child(2)",
      "element_text" => "Needs you 3",
      "element_tag" => "h2",
      "capture" => %{"html" => "<h2>Needs you <span>3</span></h2>", "width" => 180, "height" => 22}
    }

    %{attrs: attrs}
  end

  test "a design comment keeps its element, its capture and its trimmed body", %{attrs: attrs} do
    changeset = PlanComment.changeset(%PlanComment{}, attrs)

    assert %PlanComment{
             target: :design,
             status: :unsent,
             body: "Say how long the oldest one has waited.",
             selector: "#lane-needs-you > header:nth-child(1) > h2:nth-child(2)",
             element_text: "Needs you 3",
             capture: %PlanCommentCapture{html: "<h2>Needs you <span>3</span></h2>", width: 180, height: 22}
           } = Ecto.Changeset.apply_action!(changeset, :insert)
  end

  test "a blank body, a bad key, an overlong or quoted selector and a missing capture are refused", %{attrs: attrs} do
    assert %{body: ["can't be blank"]} = errors_on(PlanComment.changeset(%PlanComment{}, %{attrs | "body" => "  "}))

    assert %{option_key: ["has invalid format"]} =
             errors_on(PlanComment.changeset(%PlanComment{}, %{attrs | "option_key" => "../x"}))

    long = "#a" <> String.duplicate(" > div:nth-child(1)", 60)
    assert %{selector: [_too_long]} = errors_on(PlanComment.changeset(%PlanComment{}, %{attrs | "selector" => long}))

    assert %{selector: ["has invalid format"]} =
             errors_on(PlanComment.changeset(%PlanComment{}, %{attrs | "selector" => "a`b"}))

    assert %{capture: ["can't be blank"]} = errors_on(PlanComment.changeset(%PlanComment{}, Map.delete(attrs, "capture")))
    assert %{target: ["is invalid"]} = errors_on(PlanComment.changeset(%PlanComment{}, %{attrs | "target" => "slide"}))
  end

  test "the element's text is trimmed, its spaces collapsed, cut at 200 and may be empty", %{attrs: attrs} do
    long =
      PlanComment.changeset(%PlanComment{}, %{attrs | "element_text" => "  Needs\n   you " <> String.duplicate("x", 300)})

    assert %PlanComment{element_text: "Needs you " <> rest} = Ecto.Changeset.apply_action!(long, :insert)
    assert String.length("Needs you " <> rest) == 200

    empty = PlanComment.changeset(%PlanComment{}, %{attrs | "element_text" => "  "})
    assert %PlanComment{element_text: ""} = Ecto.Changeset.apply_action!(empty, :insert)
  end

  test "status, task and author cannot be cast", %{attrs: attrs} do
    changeset =
      PlanComment.changeset(
        %PlanComment{},
        Map.merge(attrs, %{"status" => "sent", "task_id" => "tsk_x", "user_id" => "usr_x"})
      )

    assert %PlanComment{status: :unsent, task_id: nil, user_id: nil} = Ecto.Changeset.apply_action!(changeset, :insert)
  end

  test "a written message reads back as its sections and numbered comments" do
    design = %{options: [%{key: "waiting-lanes", title: "Lanes (by what they wait on)"}]}

    comments = [
      %PlanComment{
        target: :design,
        option_key: "waiting-lanes",
        selector: "#lane-needs-you > header:nth-child(1) > h2:nth-child(2)",
        element_text: ~s(Needs "you" 3),
        element_tag: "h2",
        body: "Say how long the oldest one has waited.\n\n> Not only the count.\n2. `#x` \"y\""
      },
      %PlanComment{
        target: :design,
        option_key: "waiting-lanes",
        selector: "#group-by-project",
        element_text: "",
        element_tag: "label",
        body: "Drop it."
      }
    ]

    message = PlanComment.calculate_message(comments, design)

    assert message == """
           2 comments on the design

           On Lanes (by what they wait on) (waiting-lanes):

           1. `#lane-needs-you > header:nth-child(1) > h2:nth-child(2)` "Needs "you" 3"
           > Say how long the oldest one has waited.
           >
           > > Not only the count.
           > 2. `#x` "y"

           2. `#group-by-project` <label>
           > Drop it.\
           """

    assert %{
             count: 2,
             sections: [
               %{
                 target: :design,
                 title: "Lanes (by what they wait on)",
                 key: "waiting-lanes",
                 comments: [
                   %{
                     number: 1,
                     selector: "#lane-needs-you > header:nth-child(1) > h2:nth-child(2)",
                     text: ~s(Needs "you" 3),
                     tag: nil,
                     body: "Say how long the oldest one has waited.\n\n> Not only the count.\n2. `#x` \"y\""
                   },
                   %{number: 2, selector: "#group-by-project", text: "", tag: "label", body: "Drop it."}
                 ]
               }
             ]
           } = PlanComment.parse_message(message)
  end

  test "comments on more than one option are a section each, and read back so" do
    design = %{options: [%{key: "a", title: "First"}, %{key: "b", title: "Second"}]}

    comments = [
      %PlanComment{target: :design, option_key: "a", selector: "#x", element_text: "X", element_tag: "p", body: "One."},
      %PlanComment{target: :design, option_key: "b", selector: "#y", element_text: "Y", element_tag: "p", body: "Two."}
    ]

    assert %{
             count: 2,
             sections: [
               %{title: "First", key: "a", comments: [%{number: 1, body: "One."}]},
               %{title: "Second", key: "b", comments: [%{number: 2, body: "Two."}]}
             ]
           } = comments |> PlanComment.calculate_message(design) |> PlanComment.parse_message()
  end

  test "an option the design no longer names is called by its key" do
    comment = %PlanComment{
      target: :design,
      option_key: "gone",
      selector: "#a",
      element_text: "A",
      element_tag: "p",
      body: "Hm."
    }

    assert PlanComment.calculate_message([comment], nil) =~ "1 comment on the design\n\nOn gone (gone):"
  end

  test "a typed message that only looks like a round does not read back" do
    for text <- [
          "Looks good to me.",
          "1 comment on the design",
          "1 comment on the design\n\nOn A (a):",
          "1 comment on the design\n\nOn A (a):\n\n1. `#a` \"A\"",
          "2 comments on the design\n\nOn A (a):\n\n1. `#a` \"A\"\n> Fix it.",
          "1 comment on the design\n\nOn A (a):\n\n2. `#a` \"A\"\n> Fix it.",
          "1 comment on the design\n\nOn A (a):\n\n1. `#a` \"A\"\n> Fix it.\nand more",
          "1 comment on the design\n\nThe A option:\n\n1. `#a` \"A\"\n> Fix it.",
          nil
        ] do
      assert PlanComment.parse_message(text) == nil
    end
  end

  test "a ticket or plan comment needs its line's kind, label, occurrence and text, and keeps a long text uncut" do
    long = "A page that never goes idle " <> String.duplicate("still loads ", 60)

    changeset =
      PlanComment.changeset(%PlanComment{}, %{
        "target" => "ticket",
        "body" => "Make it 5.",
        "element_kind" => "list_item",
        "element_label" => "Criterion 2",
        "element_occurrence" => 1,
        "element_text" => long
      })

    assert %PlanComment{
             target: :ticket,
             element_kind: :list_item,
             element_label: "Criterion 2",
             element_occurrence: 1,
             element_text: ^long
           } = Ecto.Changeset.apply_action!(changeset, :insert)

    assert %{
             element_kind: ["can't be blank"],
             element_label: ["can't be blank"],
             element_occurrence: ["can't be blank"],
             element_text: ["can't be blank"]
           } = errors_on(PlanComment.changeset(%PlanComment{}, %{"target" => "plan", "body" => "Hm."}))

    assert %{element_occurrence: ["must be greater than 0"]} =
             errors_on(
               PlanComment.changeset(%PlanComment{}, %{
                 "target" => "plan",
                 "body" => "Hm.",
                 "element_kind" => "file",
                 "element_label" => "File 1",
                 "element_occurrence" => 0,
                 "element_text" => "lib/rail.ex"
               })
             )
  end

  test "a round is the design's comments, then the ticket's, then the plan's, each oldest first" do
    at = ~U[2026-10-07 12:00:00.000000Z]
    later = DateTime.shift(at, second: 1)

    plan = %PlanComment{id: "pcm_1", target: :plan, inserted_at: at}
    ticket_b = %PlanComment{id: "pcm_3", target: :ticket, inserted_at: at}
    ticket_a = %PlanComment{id: "pcm_2", target: :ticket, inserted_at: at}
    design = %PlanComment{id: "pcm_4", target: :design, inserted_at: later}

    assert [^design, ^ticket_a, ^ticket_b, ^plan] = PlanComment.calculate_round([plan, ticket_b, design, ticket_a])
  end

  test "a round on the design, the ticket and the plan names them all, quotes each line and reads back" do
    design = %{options: [%{key: "a", title: "First"}]}

    comments = [
      %PlanComment{target: :design, option_key: "a", selector: "#x", element_text: "X", element_tag: "p", body: "One."},
      %PlanComment{
        target: :ticket,
        element_kind: :list_item,
        element_label: "Criterion 2",
        element_occurrence: 1,
        element_text: "A page that never goes idle starts recording after 10 seconds.",
        body: "Make it 5.\n| not a quote"
      },
      %PlanComment{
        target: :plan,
        element_kind: :code,
        element_label: "Code line 2",
        element_occurrence: 1,
        element_text: "  settle_cap_ms: 10_000,",
        body: "5_000."
      }
    ]

    message = PlanComment.calculate_message(comments, design)

    assert message == """
           3 comments on the design, the ticket and the plan

           On First (a):

           1. `#x` "X"
           > One.

           On the ticket:

           2. Criterion 2
           | A page that never goes idle starts recording after 10 seconds.
           > Make it 5.
           > | not a quote

           On the plan:

           3. Code line 2
           |   settle_cap_ms: 10_000,
           > 5_000.\
           """

    assert %{
             count: 3,
             sections: [
               %{target: :design, key: "a", comments: [%{number: 1, body: "One."}]},
               %{
                 target: :ticket,
                 title: "Ticket",
                 comments: [
                   %{
                     number: 2,
                     label: "Criterion 2",
                     text: "A page that never goes idle starts recording after 10 seconds.",
                     body: "Make it 5.\n| not a quote"
                   }
                 ]
               },
               %{
                 target: :plan,
                 title: "Plan",
                 comments: [%{number: 3, label: "Code line 2", text: "settle_cap_ms: 10_000,", body: "5_000."}]
               }
             ]
           } = PlanComment.parse_message(message)
  end

  test "two groups are named with and, and a ticket round alone reads back" do
    ticket = %PlanComment{
      target: :ticket,
      element_kind: :priority,
      element_label: "Priority",
      element_occurrence: 1,
      element_text: "Medium",
      body: "Make it High."
    }

    plan = %{ticket | target: :plan, element_kind: :file, element_label: "File 1", element_text: "lib/rail.ex"}

    assert PlanComment.calculate_message([ticket, plan], nil) =~ ~r/\A2 comments on the ticket and the plan\n/

    assert %{count: 1, sections: [%{target: :ticket, comments: [%{label: "Priority", text: "Medium"}]}]} =
             [ticket] |> PlanComment.calculate_message(nil) |> PlanComment.parse_message()
  end

  test "a ticket round whose heading, quote or body is off does not read back" do
    for text <- [
          "1 comment on the plan\n\nOn the ticket:\n\n1. Priority\n| Medium\n> High.",
          "1 comment on the ticket\n\nOn the ticket:\n\n1. Priority\n> High.",
          "1 comment on the ticket\n\nOn the ticket:\n\n1. Priority\n| Medium",
          "1 comment on the ticket\n\nOn the ticket:\n\nPriority\n| Medium\n> High."
        ] do
      assert PlanComment.parse_message(text) == nil
    end
  end
end
