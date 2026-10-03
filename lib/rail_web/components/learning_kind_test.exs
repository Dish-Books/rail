defmodule RailWeb.Components.LearningKindTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Learnings.Schemas.Learning
  alias RailWeb.Components.LearningKind

  test "each kind has its icon and label" do
    icons =
      for kind <- Learning.kinds() do
        html = render_component(&LearningKind.learning_kind/1, kind: kind)
        assert html =~ Learning.kind_label(kind)
        [icon] = Regex.run(~r/pi-[a-z-]+/, html)
        icon
      end

    assert icons == [
             "pi-ruler",
             "pi-gavel",
             "pi-terminal-window",
             "pi-package",
             "pi-paint-brush",
             "pi-flask",
             "pi-funnel-simple"
           ]
  end
end
