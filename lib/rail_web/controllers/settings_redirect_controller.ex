defmodule RailWeb.SettingsRedirectController do
  @moduledoc false
  use RailWeb, :controller

  def index(conn, _params) do
    redirect(conn, to: ~p"/settings/connected-accounts")
  end
end
