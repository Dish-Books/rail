defmodule RailWeb.HealthController do
  use RailWeb, :controller

  def health(conn, _params) do
    text(conn, "ok")
  end
end
