defmodule RailWeb.ErrorHTMLTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.Template, only: [render_to_string: 4]

  test "renders 404.html" do
    assert render_to_string(RailWeb.ErrorHTML, "404", "html", []) == "Not Found"
  end

  test "renders 500.html" do
    assert render_to_string(RailWeb.ErrorHTML, "500", "html", []) == "Internal Server Error"
  end
end
