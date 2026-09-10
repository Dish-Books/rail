defmodule RailWeb.Components.DesignPanelTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Artifacts.Schemas.Design
  alias Rail.Domain.Embeds.DesignDirection
  alias RailWeb.Components.DesignPanel

  test "renders all design directions when picked_key is nil" do
    dir1 = %DesignDirection{
      key: "minimal",
      title: "Minimal Subtle",
      notes: "Clean monochrome style",
      still_url: "https://example.com/still1.png"
    }

    dir2 = %DesignDirection{
      key: "bold",
      title: "Bold Vibrant",
      notes: "High-contrast colors",
      linear_asset_id: "ast_dsg_2"
    }

    design = %Design{
      version: 2,
      canvas_url: "https://canvas.example.com/designs/123",
      picked_key: nil,
      directions: [dir1, dir2]
    }

    html = render_component(&DesignPanel.design_panel/1, design: design)

    assert html =~ "id=\"design-panel\""
    assert html =~ "id=\"design-panel-title\""
    assert html =~ "Design directions"
    assert html =~ "id=\"design-version-pill\""
    assert html =~ "v2"
    assert html =~ "id=\"design-canvas-link\""
    assert html =~ "https://canvas.example.com/designs/123"

    assert html =~ "id=\"design-direction-card-minimal\""
    assert html =~ "Minimal Subtle"
    assert html =~ "Clean monochrome style"
    assert html =~ "https://example.com/still1.png?v=2"

    assert html =~ "id=\"design-direction-card-bold\""
    assert html =~ "Bold Vibrant"
    assert html =~ "High-contrast colors"
    assert html =~ "/assets/design/ast_dsg_2?v=2"

    refute html =~ "data-qa=\"design_direction_picked\""
  end

  test "renders only the picked direction when picked_key is present" do
    dir1 = %{
      key: "minimal",
      title: "Minimal Subtle",
      notes: "Clean monochrome style",
      still_url: "https://example.com/still1.png"
    }

    dir2 = %{
      key: "bold",
      title: "Bold Vibrant",
      notes: "High-contrast colors",
      still_url: "https://example.com/still2.png"
    }

    design = %{
      version: 1,
      canvas_url: "https://canvas.example.com/designs/456",
      picked_key: "minimal",
      directions: [dir1, dir2]
    }

    html = render_component(&DesignPanel.design_panel/1, design: design)

    assert html =~ "id=\"design-direction-card-minimal\""
    assert html =~ "Minimal Subtle"
    assert html =~ "border-2 border-[var(--color-primary)]"
    assert html =~ "id=\"design-direction-picked-minimal\""
    assert html =~ "Picked"

    refute html =~ "id=\"design-direction-card-bold\""
    refute html =~ "Bold Vibrant"
  end

  test "falls back to all directions if picked_key does not match any direction" do
    dir1 = %{key: "dir-1", title: "Option 1", notes: "Notes 1"}
    design = %{version: 1, picked_key: "non-existent", directions: [dir1]}

    html = render_component(&DesignPanel.design_panel/1, design: design)

    assert html =~ "id=\"design-direction-card-dir-1\""
    assert html =~ "Option 1"
    refute html =~ "data-qa=\"design_direction_picked\""
  end

  test "omits canvas link when canvas_url is empty or nil" do
    design = %{version: 1, canvas_url: nil, directions: []}
    html = render_component(&DesignPanel.design_panel/1, design: design)

    refute html =~ "id=\"design-canvas-link\""
  end

  test "handles empty or missing directions and empty still images gracefully" do
    dir_no_still = %{key: "empty-img", title: "No Image Direction", notes: nil, still_url: ""}
    design = %{version: 1, directions: [dir_no_still]}

    html = render_component(&DesignPanel.design_panel/1, design: design)

    assert html =~ "id=\"design-direction-card-empty-img\""
    assert html =~ "No Image Direction"
    refute html =~ "id=\"design-still-img-empty-img\""
    refute html =~ "id=\"design-direction-notes-empty-img\""

    # nil design and non-map direction
    empty_html = render_component(&DesignPanel.design_panel/1, design: nil)
    assert empty_html =~ "id=\"design-panel\""

    invalid_dir_html = render_component(&DesignPanel.design_panel/1, design: %{version: 1, directions: [nil]})
    assert invalid_dir_html =~ "id=\"design-panel\""
  end
end
