defmodule Rail.Pipeline.Utils.FormatCommentsTest do
  use ExUnit.Case, async: true

  import Rail.Pipeline.Utils.FormatComments

  alias Rail.Issues.Schemas.Comment

  test "says so when the issue has no comments" do
    assert format_comments([]) == "The issue has no comments."
  end

  test "writes comments oldest first with each reply inside the comment it answers" do
    reply = %Comment{
      id: "com_3",
      parent_id: "com_2",
      author_name: "Bob",
      body: "Only on Sysco bills.\n",
      inserted_at: ~U[2026-07-14 12:30:00.000000Z]
    }

    later = %Comment{
      id: "com_2",
      author_name: "Ana",
      body: "Seen it twice this week.",
      inserted_at: ~U[2026-07-14 12:00:00.000000Z],
      replies: [reply]
    }

    earlier = %Comment{
      id: "com_1",
      author_name: nil,
      body: "  Customer reported it.  ",
      inserted_at: ~U[2026-07-13 09:00:00.000000Z],
      replies: []
    }

    assert format_comments([later, reply, earlier]) ==
             """
             <comment author="Unknown" at="2026-07-13T09:00:00.000000Z">
             Customer reported it.
             </comment>

             <comment author="Ana" at="2026-07-14T12:00:00.000000Z">
             Seen it twice this week.
             <reply author="Bob" at="2026-07-14T12:30:00.000000Z">
             Only on Sysco bills.
             </reply>
             </comment>\
             """
  end
end
