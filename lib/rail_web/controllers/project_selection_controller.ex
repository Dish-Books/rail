defmodule RailWeb.ProjectSelectionController do
  @moduledoc false
  use RailWeb, :controller

  def select(conn, params) do
    conn =
      case params["project_id"] do
        id when is_binary(id) and id != "" -> put_session(conn, :selected_project_id, id)
        _blank -> delete_session(conn, :selected_project_id)
      end

    return_to = params["return_to"]

    # Only a path on this site, so the redirect cannot send the browser elsewhere.
    # The characters Phoenix refuses in a local redirect fall back too, rather than raise.
    local_path? =
      is_binary(return_to) and String.starts_with?(return_to, "/") and
        not String.starts_with?(return_to, "//") and
        not String.contains?(return_to, ["\\", "/%09", "/\t"])

    redirect(conn, to: if(local_path?, do: return_to, else: ~p"/"))
  end
end
