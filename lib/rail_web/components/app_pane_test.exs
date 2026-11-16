defmodule RailWeb.Components.AppPaneTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline.Schemas.Preview
  alias Rail.Pipeline.Schemas.ScreenComment
  alias RailWeb.Components.AppPane

  setup do
    live = %Preview{status: :live, url: "https://pr-7.preview.example.com", live_sha: "abc1234def5678"}

    %{
      live: live,
      assigns: [
        preview: nil,
        has_pr: true,
        commenting: false,
        commentable: true,
        draft: nil,
        comments: [],
        target: nil
      ],
      element: %{
        selector: "#main > button:nth-child(2)",
        text: "Save",
        tag: "button",
        x: 192,
        y: 108,
        width: 384,
        height: 216,
        url: "https://pr-7.preview.example.com/tasks?tab=open",
        picture: "/scratch/app/comments/elm_1.jpg"
      }
    }
  end

  test "a task with no pull request yet says where its preview will come from, and offers nothing", %{
    assigns: assigns
  } do
    doc =
      (&AppPane.app_pane/1) |> render_component(Keyword.put(assigns, :has_pr, false)) |> Floki.parse_fragment!()

    assert doc |> Floki.find("[data-qa=app_status].text-slate-500") |> Floki.text() |> String.trim() ==
             "No pull request yet"

    assert doc |> Floki.find("[data-qa=app_no_pr]") |> Floki.text() =~ "deployed to an address of its own"
    assert [] = Floki.find(doc, "[data-qa=app_host]")
    assert [] = Floki.find(doc, "#app-sign-in")
    assert [] = Floki.find(doc, "#app-open-new-tab")
    assert [] = Floki.find(doc, "#app-screen")
    assert [] = Floki.find(doc, "[data-qa=app_error]")
  end

  # Rail has not looked yet, or looked and found an older commit: either way the push is on its way.
  test "a preview not yet looked for, or serving an older commit, is deploying, naming its host once known", %{
    assigns: assigns
  } do
    doc = (&AppPane.app_pane/1) |> render_component(assigns) |> Floki.parse_fragment!()

    assert doc |> Floki.find("[data-qa=app_status].text-blue-600") |> Floki.text() |> String.trim() == "Deploying…"
    assert doc |> Floki.find("[data-qa=app_deploying]") |> Floki.text() =~ "Deploying the latest commit."
    assert [] = Floki.find(doc, "[data-qa=app_host]")

    deploying = %Preview{status: :deploying, url: "https://pr-7.preview.example.com", live_sha: "abc1234def5678"}

    doc =
      (&AppPane.app_pane/1) |> render_component(Keyword.put(assigns, :preview, deploying)) |> Floki.parse_fragment!()

    assert doc |> Floki.find("[data-qa=app_host]") |> Floki.text() |> String.trim() == "pr-7.preview.example.com"
    refute Floki.text(doc) =~ "abc1234"
    assert [] = Floki.find(doc, "#app-sign-in")
    assert [] = Floki.find(doc, "#app-screen")
  end

  test "a preview whose task has no worktree any more is gone", %{assigns: assigns} do
    gone = %Preview{status: :gone, url: "https://pr-7.preview.example.com"}
    doc = (&AppPane.app_pane/1) |> render_component(Keyword.put(assigns, :preview, gone)) |> Floki.parse_fragment!()

    assert doc |> Floki.find("[data-qa=app_status].text-slate-500") |> Floki.text() |> String.trim() == "Gone"
    assert doc |> Floki.find("[data-qa=app_gone]") |> Floki.text() =~ "no worktree any more"
    assert [] = Floki.find(doc, "#app-sign-in")
    assert [] = Floki.find(doc, "#app-screen")
  end

  test "a live preview names its commit, and opens in a new tab at its login address once Rail knows it", %{
    assigns: assigns,
    live: live
  } do
    running = Keyword.put(assigns, :preview, live)
    doc = (&AppPane.app_pane/1) |> render_component(running) |> Floki.parse_fragment!()

    assert doc |> Floki.find("[data-qa=app_host]") |> Floki.text() |> String.trim() == "pr-7.preview.example.com"
    assert Floki.text(doc) =~ "abc1234"
    refute Floki.text(doc) =~ "abc1234d"
    assert [] = Floki.find(doc, "#app-open-new-tab")

    doc =
      (&AppPane.app_pane/1)
      |> render_component(Keyword.put(running, :login_url, "https://pr-7.preview.example.com/dev/login"))
      |> Floki.parse_fragment!()

    assert [link] = Floki.find(doc, "#app-open-new-tab")
    assert Floki.attribute(link, "href") == ["https://pr-7.preview.example.com/dev/login"]
    assert Floki.attribute(link, "target") == ["_blank"]
    assert Floki.attribute(link, "rel") == ["noopener"]

    doc =
      (&AppPane.app_pane/1)
      |> render_component(Keyword.put(assigns, :preview, %{live | live_sha: nil}))
      |> Floki.parse_fragment!()

    refute Floki.text(doc) =~ "abc1234"
  end

  test "a live preview shows its page's path without the host, Back, Reload and Sign in again", %{
    assigns: assigns,
    live: live
  } do
    running = Keyword.put(assigns, :preview, live)

    for {url, path} <- [
          {"https://pr-7.preview.example.com/tasks?tab=open", "/tasks?tab=open"},
          {"https://pr-7.preview.example.com", "/"},
          {"http://pr-7.preview.example.com/a", "/a"},
          {"chrome-error://chromewebdata/", "chrome-error://chromewebdata/"},
          {nil, "about:blank"}
        ] do
      doc = (&AppPane.app_pane/1) |> render_component(Keyword.put(running, :url, url)) |> Floki.parse_fragment!()

      assert doc |> Floki.find("[data-qa=app_url]") |> Floki.text() |> String.trim() == path
    end

    doc = (&AppPane.app_pane/1) |> render_component(running) |> Floki.parse_fragment!()

    assert doc |> Floki.find("[data-qa=app_status].text-green-600") |> Floki.text() |> String.trim() == "Live"
    assert ["back"] = doc |> Floki.find("[data-qa=app_back]") |> Floki.attribute("phx-value-to")
    assert ["reload"] = doc |> Floki.find("[data-qa=app_reload]") |> Floki.attribute("phx-value-to")
    assert [_sign_in] = Floki.find(doc, "#app-sign-in[phx-click=app_sign_in]")
    assert [_screen] = Floki.find(doc, "#app-screen[phx-hook=AppInput][data-commenting=false].cursor-default")
    assert [_picture] = Floki.find(doc, "#app-screencast[phx-hook=BrowserScreencast]")
    assert [_toggle] = Floki.find(doc, "#design-comment-toggle[phx-click=toggle_commenting][aria-pressed=false]")
    assert [] = Floki.find(doc, "[data-qa=app_picked]")
    assert [] = Floki.find(doc, "#app-comment-form")
    assert [] = Floki.find(doc, "[data-qa=app_comments]")
  end

  test "Comment is disabled with its reason on a task that takes no comments, and crosshairs the picture when on", %{
    assigns: assigns,
    live: live
  } do
    running = Keyword.put(assigns, :preview, live)

    doc =
      (&AppPane.app_pane/1) |> render_component(Keyword.put(running, :commentable, false)) |> Floki.parse_fragment!()

    assert [_disabled] = Floki.find(doc, "#design-comment-toggle[disabled]")
    assert doc |> Floki.find("#design-comment-hint") |> Floki.text() =~ "Comments open once the task reaches Review."

    doc = (&AppPane.app_pane/1) |> render_component(Keyword.put(running, :commenting, true)) |> Floki.parse_fragment!()

    assert [_screen] = Floki.find(doc, "#app-screen[data-commenting=true].cursor-crosshair")
    assert [_toggle] = Floki.find(doc, "#design-comment-toggle[aria-pressed=true]")
  end

  test "a picked element is outlined as a share of the picture, with the comment box under it naming it", %{
    assigns: assigns,
    element: element,
    live: live
  } do
    picked =
      Keyword.merge(assigns,
        preview: live,
        commenting: true,
        draft: %{element: element, body: "Bigger."}
      )

    doc = (&AppPane.app_pane/1) |> render_component(picked) |> Floki.parse_fragment!()

    assert ["left: 10.0%; top: 10.0%; width: 20.0%; height: 20.0%;"] =
             doc |> Floki.find("[data-qa=app_picked]") |> Floki.attribute("style")

    # Under the element: its bottom, 108 + 216 pixels down, and a point more.
    assert doc |> Floki.find("#app-comment-form") |> Floki.attribute("style") ==
             ["left: 10.0%; top: #{324 / 10.8 + 1}%;"]

    on = doc |> Floki.find("#app-comment-form p") |> Floki.text(sep: " ") |> String.split() |> Enum.join(" ")
    assert on == ~s[On "Save" at /tasks?tab=open]
    assert ["#main > button:nth-child(2)"] = doc |> Floki.find("#app-comment-form p") |> Floki.attribute("title")
    assert doc |> Floki.find("[data-qa=app_comment_body]") |> Floki.text() |> String.trim() == "Bigger."
    assert [_cancel] = Floki.find(doc, "#app-comment-form button[phx-click=cancel_app_comment]")
  end

  test "an element that says nothing is named by its tag, and one low or far right keeps its box on the picture", %{
    assigns: assigns,
    element: element,
    live: live
  } do
    low = %{element | text: "", x: 1800, y: 900, height: 100}

    doc =
      (&AppPane.app_pane/1)
      |> render_component(
        Keyword.merge(assigns,
          preview: live,
          commenting: true,
          draft: %{element: low, body: ""}
        )
      )
      |> Floki.parse_fragment!()

    on = doc |> Floki.find("#app-comment-form p") |> Floki.text(sep: " ") |> String.split() |> Enum.join(" ")
    assert on == "On <button> at /tasks?tab=open"
    style = "left: #{1300 / 19.2}%; bottom: #{180 / 10.8 + 1}%;"
    assert [^style] = doc |> Floki.find("#app-comment-form") |> Floki.attribute("style")
  end

  test "the reader's unsent comments on the app list their page, element and words, each with Remove", %{
    assigns: assigns,
    live: live
  } do
    comment = %ScreenComment{id: "scm_1", source: :app, label: "/tasks", selector: "#save", body: "Say Saved."}

    doc =
      (&AppPane.app_pane/1)
      |> render_component(
        Keyword.merge(assigns,
          preview: live,
          comments: [comment],
          error: "There is no element there to comment on."
        )
      )
      |> Floki.parse_fragment!()

    assert doc |> Floki.find("[data-qa=app_comment]") |> Floki.text(sep: " ") |> String.split() |> Enum.join(" ") =~
             "/tasks · #save Say Saved."

    assert ["scm_1"] = doc |> Floki.find("[data-qa=app_comment_remove]") |> Floki.attribute("phx-value-id")

    assert doc |> Floki.find("[data-qa=app_error]") |> Floki.text() |> String.trim() ==
             "There is no element there to comment on."
  end
end
