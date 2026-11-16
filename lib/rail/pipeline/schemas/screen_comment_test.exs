defmodule Rail.Pipeline.Schemas.ScreenCommentTest do
  use ExUnit.Case, async: true

  import Rail.DataCase, only: [errors_on: 1]

  alias Rail.Pipeline.Schemas.ScreenComment

  setup do
    %{
      comment: %ScreenComment{
        key: "file-list",
        label: "File list after Send",
        commit: "e52a0bd91",
        body: "The count wraps at 1280px."
      }
    }
  end

  test "a comment needs a state's key and text, and its text is trimmed" do
    assert %{valid?: true, changes: %{key: "file-list", body: "Fold it."}} =
             ScreenComment.changeset(%ScreenComment{}, %{"key" => "file-list", "body" => "  Fold it.\n"})

    refute ScreenComment.changeset(%ScreenComment{}, %{"key" => "file-list", "body" => "   "}).valid?
    refute ScreenComment.changeset(%ScreenComment{}, %{"body" => "Fold it."}).valid?
    refute ScreenComment.changeset(%ScreenComment{}, %{"key" => "../up", "body" => "Fold it."}).valid?
  end

  test "the block names the state, the commit it was written on and the picture in the QA folder", %{
    comment: comment
  } do
    screen = %{key: "file-list", file: "screens/file-list/1.jpg", commit: "e52a0bd91"}

    assert ScreenComment.calculate_block(comment, screen, "/scratch/tsk_1") ==
             """
             <screen_comment>
             File list after Send (file-list), commented on e52a0bd
             Picture: /scratch/tsk_1/qa/screens/file-list/1.jpg
             The count wraps at 1280px.
             </screen_comment>\
             """
  end

  test "after a retake the block gives the new picture and its commit", %{comment: comment} do
    screen = %{key: "file-list", file: "screens/file-list/2.jpg", commit: "91d0f3a77"}

    assert ScreenComment.calculate_block(comment, screen, "/scratch/tsk_1") =~
             "Picture: /scratch/tsk_1/qa/screens/file-list/2.jpg, retaken on 91d0f3a\n"
  end

  test "with no picture of the state left, and no commit, the block says neither", %{comment: comment} do
    assert ScreenComment.calculate_block(%{comment | commit: nil}, nil, "/scratch/tsk_1") ==
             "<screen_comment>\nFile list after Send (file-list)\nThe count wraps at 1280px.\n</screen_comment>"
  end

  describe "on the running app" do
    setup do
      %{
        comment: %ScreenComment{
          source: :app,
          key: "app",
          label: "/checkout?step=2",
          commit: "e52a0bd91",
          selector: "#checkout > button:nth-child(2)",
          element_text: "Pay now",
          element_tag: "button",
          picture_path: "/scratch/tsk_1/app/comments/elm_1.jpg",
          body: "This should say Pay $12."
        }
      }
    end

    # The page and the picture are what Rail's browser saw, so they are the caller's to set, never the client's.
    test "a comment needs text, an element and the page it is on, and is on the app whatever the client says" do
      attrs = %{
        "body" => "  Say the amount.\n",
        "selector" => "#checkout > button:nth-child(2)",
        "element_text" => "Pay now",
        "element_tag" => "button",
        "source" => "shot",
        "key" => "file-list",
        "picture_path" => "/etc/passwd"
      }

      assert %{
               valid?: true,
               changes:
                 %{source: :app, key: "app", body: "Say the amount.", selector: "#checkout > button:nth-child(2)"} =
                   changes
             } = ScreenComment.app_changeset(%ScreenComment{label: "/checkout"}, attrs)

      refute Map.has_key?(changes, :picture_path)

      assert %{body: ["can't be blank"], selector: ["can't be blank"], label: ["can't be blank"]} =
               errors_on(ScreenComment.app_changeset(%ScreenComment{}, %{"body" => " "}))
    end

    test "the selector keeps to the grammar design comments use, and each field to its length" do
      attrs = %{"body" => "Hi.", "selector" => "div[onclick=alert(1)]"}

      assert %{selector: ["has invalid format"]} =
               errors_on(ScreenComment.app_changeset(%ScreenComment{label: "/"}, attrs))

      too_long = %{
        "body" => "Hi.",
        "selector" => String.duplicate("a", 1001),
        "element_text" => String.duplicate("a", 201),
        "element_tag" => String.duplicate("a", 65)
      }

      assert %{selector: [_selector], element_text: [_text], element_tag: [_tag]} =
               errors_on(ScreenComment.app_changeset(%ScreenComment{label: "/"}, too_long))
    end

    test "the block names the page, the commit, the element by its selector and text, and its picture", %{
      comment: comment
    } do
      assert ScreenComment.calculate_block(comment, nil, "/scratch/tsk_1") ==
               """
               <app_comment>
               In the running app at /checkout?step=2, commented on e52a0bd
               Element: `#checkout > button:nth-child(2)` "Pay now"
               Picture: /scratch/tsk_1/app/comments/elm_1.jpg
               This should say Pay $12.
               </app_comment>\
               """
    end

    test "an element with no text is named by its tag, and a commit or picture it lacks is left out", %{comment: comment} do
      comment = %{comment | commit: nil, element_text: "", picture_path: nil, element_tag: "svg"}

      assert ScreenComment.calculate_block(comment, nil, "/scratch/tsk_1") ==
               "<app_comment>\nIn the running app at /checkout?step=2\nElement: `#checkout > button:nth-child(2)` svg\n" <>
                 "This should say Pay $12.\n</app_comment>"
    end
  end
end
