defmodule Rail.Pipeline.Actions.SplitMessageImagesTest do
  use ExUnit.Case, async: true

  alias Rail.Pipeline

  test "takes the pictures out of a queued message by name, in order, leaving what was typed" do
    queued =
      "Look at this\n[Attached image, open it with Read: /scratch/attachments/a.png]\n\n" <>
        "And this\n[Attached image, open it with Read: /scratch/attachments/b.jpg]"

    assert {"Look at this\n\nAnd this", ["a.png", "b.jpg"]} = Pipeline.split_message_images(queued)
  end

  test "a message with no pictures is all words, and one with only pictures has none" do
    assert {"Just words", []} = Pipeline.split_message_images("Just words")
    assert {"", ["a.png"]} = Pipeline.split_message_images("[Attached image, open it with Read: /x/a.png]")
  end
end
