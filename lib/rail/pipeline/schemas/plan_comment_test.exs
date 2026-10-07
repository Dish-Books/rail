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
    assert %{target: ["is invalid"]} = errors_on(PlanComment.changeset(%PlanComment{}, %{attrs | "target" => "ticket"}))
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
end
