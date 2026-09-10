defmodule RailWeb.Layouts do
  @moduledoc false
  use RailWeb, :html

  import RailWeb.CoreComponents

  embed_templates "layouts/*"
end
