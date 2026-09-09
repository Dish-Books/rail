defmodule RailWeb.CoreComponents do
  @moduledoc false
  use RailWeb, :html

  defdelegate settings_nav(assigns), to: RailWeb.Components.SettingsNav
end
