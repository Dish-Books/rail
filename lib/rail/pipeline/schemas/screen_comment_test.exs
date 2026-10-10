defmodule Rail.Pipeline.Schemas.ScreenCommentTest do
  use ExUnit.Case, async: true

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
end
