defmodule Rail.Pipeline.Schemas.PreviewTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline.Schemas.Preview
  alias Rail.Projects.Schemas.Project

  test "a preview needs its task, address and status" do
    assert %{task_id: ["can't be blank"], url: ["can't be blank"], status: ["can't be blank"]} =
             errors_on(Preview.changeset(%Preview{}, %{}))

    assert %{status: ["is invalid"]} = errors_on(Preview.changeset(%Preview{}, %{status: "running"}))
  end

  test "its tab is the App item's browser" do
    assert Preview.browser_name() == "app"
  end

  test "a pull request's address is its project's template with the number in it, without a trailing slash" do
    assert Preview.url(%Project{preview_url_template: "https://pr-{pr_number}.preview.example.com/"}, 42) ==
             "https://pr-42.preview.example.com"

    assert Preview.url(%Project{preview_url_template: "https://pr-{pr_number}.example.com/app"}, 7) ==
             "https://pr-7.example.com/app"
  end

  test "it opens at its project's login path, or at its root without one" do
    preview = %Preview{url: "https://pr-7.preview.example.com"}

    assert Preview.login_url(preview, %Project{preview_login_path: "/dev/login?as=ada"}) ==
             "https://pr-7.preview.example.com/dev/login?as=ada"

    assert Preview.login_url(preview, %Project{preview_login_path: nil}) == "https://pr-7.preview.example.com/"
  end

  test "its database is named by its project's pattern, or not at all" do
    assert Preview.database(%Project{preview_database: "Example PR {pr_number}"}, 42) == "Example PR 42"
    assert Preview.database(%Project{preview_database: nil}, 42) == nil
  end

  test "the Access token is the client id and secret together, or none when either is missing" do
    assert Preview.access(%Project{preview_access_client_id: "id.access", preview_access_client_secret: "secret"}) ==
             %{client_id: "id.access", client_secret: "secret"}

    assert Preview.access(%Project{preview_access_client_id: "id.access"}) == nil
    assert Preview.access(%Project{}) == nil
  end

  test "only a preview serving the head commit is live" do
    assert Preview.live?(%Preview{status: :live})
    refute Preview.live?(%Preview{status: :deploying})
    refute Preview.live?(%Preview{status: :gone})
    refute Preview.live?(nil)
  end
end
