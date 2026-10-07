defmodule RailWeb.Components.PlanDiagramTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import RailTest.Helpers
  import RailWeb.Utils.BuildPlanSheet

  alias Rail.Pipeline.Schemas.PlanComment
  alias RailWeb.Components.PlanDiagram

  test "draws a card the hook fills in, with its source as text and full screen hidden until the browser has it" do
    source = "flowchart LR\n  A[\"Pipeline\"] --> B\n"

    html =
      (&PlanDiagram.plan_diagram/1)
      |> render_component(
        diagram: %{
          kind: :change,
          source: source,
          type_label: "Flowchart",
          caption: "Flowchart",
          source_lines: [],
          nodes: []
        },
        view: :diagram,
        event: "diagram_view"
      )
      |> Floki.parse_fragment!()

    assert [figure] = Floki.find(html, "figure[phx-hook='PlanDiagram']")
    assert [id] = Floki.attribute(figure, "id")
    assert id =~ "plan-diagram-change-"
    assert [class] = Floki.attribute(figure, "class")
    assert class =~ "not-prose"
    assert Floki.text(Floki.find(html, "figcaption")) =~ "Change diagram"
    assert Floki.find(html, ".pi-flow-arrow") != []
    assert [pre] = Floki.find(html, "pre[data-diagram-source]")
    assert Floki.text(pre) == source
    assert Floki.attribute(html, "[data-diagram-canvas]", "phx-update") == ["ignore"]
    assert Floki.attribute(html, "[data-diagram-error]", "phx-update") == ["ignore"]
    assert [fullscreen] = Floki.attribute(html, "button[data-diagram-fullscreen]", "class")
    assert fullscreen =~ ~r/(^|\s)hidden(\s|$)/
    assert Floki.attribute(html, "button[phx-value-view='change:diagram']", "aria-pressed") == ["true"]
    assert Floki.attribute(html, "button[phx-value-view='change:source']", "aria-pressed") == ["false"]
    assert Floki.attribute(html, "button[phx-value-view='change:source']", "phx-click") == ["diagram_view"]
  end

  test "the Source view presses Source and sends to its target" do
    html =
      (&PlanDiagram.plan_diagram/1)
      |> render_component(
        diagram: %{
          kind: :call_flow,
          source: "sequenceDiagram\n  A->>B: hi\n",
          type_label: "Sequence diagram",
          caption: "From A to B",
          source_lines: [],
          nodes: []
        },
        view: :source,
        event: "diagram_view",
        target: "#architect-stage"
      )
      |> Floki.parse_fragment!()

    assert Floki.text(Floki.find(html, "figcaption")) =~ "Call flow"
    assert Floki.text(Floki.find(html, "figcaption")) =~ "From A to B"
    assert Floki.find(html, ".pi-arrows-left-right") != []
    assert Floki.attribute(html, "button[phx-value-view='call_flow:source']", "aria-pressed") == ["true"]
    assert Floki.attribute(html, "button[phx-value-view='call_flow:diagram']", "aria-pressed") == ["false"]
    assert Floki.attribute(html, "button[phx-value-view='call_flow:source']", "phx-target") == ["#architect-stage"]
  end

  test "markup in a label reaches the page as text, never as elements" do
    source = ~s{flowchart LR\n  A["<script>alert(1)</script>"] --> B["<img src=x onerror=alert(1)>"]\n}

    html =
      render_component(&PlanDiagram.plan_diagram/1,
        diagram: %{
          kind: :change,
          source: source,
          type_label: "Flowchart",
          caption: "<b>caption</b>",
          source_lines: [],
          nodes: []
        },
        view: :diagram,
        event: "diagram_view"
      )

    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    assert html =~ "&lt;img src=x onerror=alert(1)&gt;"
    assert html =~ "&lt;b&gt;caption&lt;/b&gt;"
    refute html =~ "<script"
    refute html =~ "<img"
    refute html =~ "<b>"
  end

  test "a rewritten diagram gets a card of its own, so the hook draws it again" do
    ids =
      for source <- ["flowchart LR\n  A --> B\n", "flowchart LR\n  A --> C\n"] do
        (&PlanDiagram.plan_diagram/1)
        |> render_component(
          diagram: %{
            kind: :change,
            source: source,
            type_label: "Flowchart",
            caption: "Flowchart",
            source_lines: [],
            nodes: []
          },
          view: :diagram,
          event: "diagram_view"
        )
        |> Floki.parse_fragment!()
        |> Floki.attribute("figure", "id")
      end

    assert [[first], [second]] = ids
    assert first != second
  end

  test "Source view numbers each line, the hook gets the nodes and which have comments, and a node's cards go under
        the figure naming it" do
    %{diagrams: [diagram | _call_flow]} = build_plan_sheet(sheet_plan())
    [_rs, %{key: key} = pipeline | _nodes] = diagram.nodes

    comment = %PlanComment{
      id: "pcm_node",
      target: :plan,
      element_kind: :node,
      element_label: "Change diagram node",
      element_text: "P",
      body: "Name it Pipeline."
    }

    html =
      (&PlanDiagram.plan_diagram/1)
      |> render_component(
        diagram: diagram,
        view: :source,
        event: "diagram_view",
        offered: true,
        placed: %{pipeline.key => [{comment, 3}]}
      )
      |> Floki.parse_fragment!()

    assert [figure] = Floki.find(html, "figure")
    assert [nodes] = Floki.attribute(figure, "data-nodes")

    assert [%{"id" => "RS", "commented" => false}, %{"id" => "P", "commented" => true, "key" => ^key}, %{"id" => "SB"}] =
             Jason.decode!(nodes)

    assert Floki.attribute(figure, "data-offered") == ["true"]
    assert [pre] = Floki.find(html, "pre[data-diagram-source]")
    assert Floki.text(pre) == diagram.source

    assert ["1", "2", "3", "4", "5"] =
             html |> Floki.find("[data-qa='line_number']") |> Enum.map(&String.trim(Floki.text(&1)))

    assert length(Floki.find(html, "[data-qa='line_comment_add']")) == 5
    assert Floki.text(Floki.find(html, "[data-qa='document_comment_line']")) =~ "Node P"
    assert Floki.text(html) =~ "Name it Pipeline."
  end
end
